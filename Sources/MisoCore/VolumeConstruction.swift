import Darwin
import Foundation

public enum VolumeConstruction {
  enum Kind: String, Codable, CaseIterable { case main, isc, recovery }
  static let expectedRoles: [Kind: Set<String>] = [
    .main: ["System", "Data", "Preboot", "Recovery", "VM", "Update"],
    .isc: ["Preboot", "Hardware", "xART", "Recovery"], .recovery: ["Recovery", "Update"],
  ]

  public struct Receipt: Codable, Sendable {
    public let profile: RestoreProfile
    public let preparedJournal: ImageBundle.FileRecord
    public let sourceJournal: ImageBundle.FileRecord
    public let disk: ImageBundle.FileRecord
    public let system: SystemConstruction.SystemIdentity
    public let volumeGroup: UUID
    public let containers: [String: APFSTopology.Container]
    public let layout: DiskLayout
  }

  struct PartitionInfo: Decodable {
    let identifier: UUID
    let size: UInt64
    let offset: UInt64
    let parent: String
    enum CodingKeys: String, CodingKey {
      case identifier = "DiskUUID"
      case size = "TotalSize"
      case offset = "PartitionMapPartitionOffset"
      case parent = "ParentWholeDisk"
    }
  }

  struct Groups: Decodable {
    struct Container: Decodable {
      struct Group: Decodable {
        struct Volume: Decodable {
          let role: String
          let identifier: UUID
          enum CodingKeys: String, CodingKey {
            case role = "Role"
            case identifier = "DiskUUID"
          }
        }
        let identifier: UUID
        let volumes: [Volume]
        enum CodingKeys: String, CodingKey {
          case identifier = "APFSVolumeGroupUUID"
          case volumes = "Volumes"
        }
      }
      let identifier: UUID
      let groups: [Group]
      enum CodingKeys: String, CodingKey {
        case identifier = "APFSContainerUUID"
        case groups = "VolumeGroups"
      }
    }
    let containers: [Container]
    enum CodingKeys: String, CodingKey { case containers = "Containers" }
  }

  public static func run(
    prepared: URL, systemStage: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Volume construction requires administrator privileges")
    }
    let apfsVersion = try APFSPrivate.requireHost()
    let inputs = try PreparedInputs(prepared)
    let sourceJournal = try JSON.read(
      ExecutionJournal.Record.self, from: systemStage.appendingPathComponent("journal.json"))
    guard sourceJournal.operation == "seal-system", sourceJournal.status == .complete,
      !sourceJournal.vmStarted,
      let sourceResult = sourceJournal.result
    else { throw MisoError.invalid("A completed sealed System stage is required") }
    let system = try JSONDecoder().decode(
      SystemConstruction.Receipt.self, from: JSON.encode(sourceResult))
    guard system.profile == inputs.receipt.profile, system.preparedJournal == inputs.journalRecord
    else { throw MisoError.invalid("System stage belongs to different prepared inputs") }
    try validateLayout(system.layout)
    let source = try Artifacts.resolve(system.disk, under: systemStage, cancellation: cancellation)
    let journal = try ExecutionJournal(
      output: output, operation: "create-volumes", cancellation: cancellation)
    return try journal.perform {
      try journal.setMetadata("apfsVersion", value: apfsVersion)
      try journal.setMetadata("target", value: system.profile.release)
      try journal.setMetadata("preparedJournal", value: inputs.journalRecord)
      let sourceReceipt = try Artifacts.record(
        systemStage.appendingPathComponent("journal.json"), relativeTo: systemStage)
      try journal.setMetadata("sourceJournal", value: sourceReceipt)
      let sourceSession = try DiskImageSession(image: source, readOnly: true, journal: journal)
      try sourceSession.requireDetached()
      let destination = journal.output.appendingPathComponent("disk.img")
      try Artifacts.clone(source, to: destination)
      guard try SafeFile.sha256(destination) == system.disk.sha256 else {
        throw MisoError.invalid("System clone digest mismatch")
      }
      let session = try DiskImageSession(image: destination, readOnly: false, journal: journal)
      let newfs = try inputs.file("newfs_apfs", cancellation: journal.cancellation)
      let fsck = try inputs.file("fsck_apfs", cancellation: journal.cancellation)
      let signedRoot = try inputs.file("signed-system-root", cancellation: journal.cancellation)
      guard let newfsRecord = inputs.receipt.tools["newfs_apfs"],
        let fsckRecord = inputs.receipt.tools["fsck_apfs"]
      else {
        throw MisoError.invalid("Missing prepared APFS tools")
      }
      for kind in [Kind.isc, .recovery] {
        try session.withAttachment { session in
          let device = try emptyPartition(
            kind, layout: system.layout, session: session, journal: journal)
          try session.verifyOwnership()
          try journal.run(
            "format-" + kind.rawValue,
            NativeCommand.restoreTool(
              newfs, sha256: newfsRecord.sha256,
              arguments: ["-C", "-o", "maxfs=100", device]))
        }
      }
      let identifiers = try session.withAttachment { session in
        var state = try select(session)
        guard Set(state.keys) == Set(Kind.allCases), state[.isc]?.volumes.isEmpty == true,
          state[.recovery]?.volumes.isEmpty == true, let main = state[.main],
          main.identifier == system.system.container,
          main.volumes.count == 1,
          try main.volume(role: "System").identifier == system.system.volume
        else {
          throw MisoError.invalid("Initial support-container layout or System identity mismatch")
        }
        let additions: [(Kind, [(String, String)])] = [
          (
            .main,
            [
              ("Macintosh HD - Data", "D"), ("Preboot", "B"), ("Recovery", "R"), ("VM", "V"),
              ("Update", "E"),
            ]
          ),
          (.isc, [("iSCPreboot", "B"), ("Hardware", "H"), ("xART", "0"), ("Recovery", "R")]),
          (.recovery, [("Recovery", "R"), ("Update", "E")]),
        ]
        for (kind, volumes) in additions {
          guard let container = state[kind] else {
            throw MisoError.invalid("Missing target container")
          }
          for (index, value) in volumes.enumerated() {
            try session.verifyOwnership()
            try journal.run(
              "add-\(kind.rawValue)-\(index)",
              NativeCommand(
                .disks,
                arguments: [
                  "apfs", "addVolume", container.device, "APFS", value.0, "-role", value.1,
                  "-nomount",
                ]))
          }
        }
        state = try select(session)
        guard let currentMain = state[.main] else {
          throw MisoError.invalid("Missing main container")
        }
        let data = try currentMain.volume(role: "Data")
        try APFSPrivate.group(
          session, container: system.system.container, system: system.system.volume,
          data: data.identifier)
        let groups = try journal.plist(
          Groups.self, name: "verify-volume-group",
          command: NativeCommand(
            .disks, arguments: ["apfs", "listVolumeGroups", currentMain.device, "-plist"]))
        try verifyGroups(
          groups, container: system.system.container, system: system.system.volume,
          data: data.identifier)
        let placeholders =
          state[.isc]?.volumes.filter { $0.name == "xART" && $0.roles.isEmpty } ?? []
        guard placeholders.count == 1, let placeholder = placeholders.first,
          placeholder.mountPoint == nil,
          placeholder.encrypted == false, let bytes = placeholder.capacityInUse, bytes <= 32768
        else {
          throw MisoError.invalid("Invalid xART placeholder")
        }
        return (data.identifier, placeholder.identifier)
      }
      let patches = try XART.initialize(
        session, volume: identifiers.1, partition: system.layout.partitions[0], journal: journal)
      try journal.setMetadata("xart", value: patches)
      let containers = try session.withAttachment { session in
        let state = try select(session)
        try verifyRoles(state)
        for kind in Kind.allCases {
          guard let container = state[kind] else {
            throw MisoError.invalid("Missing completed container")
          }
          try session.verifyOwnership()
          try journal.run(
            "check-" + kind.rawValue,
            NativeCommand.restoreTool(
              fsck, sha256: fsckRecord.sha256,
              arguments: ["-n", "/dev/r" + container.device]))
        }
        guard let main = state[.main], main.identifier == system.system.container else {
          throw MisoError.invalid("System container identity changed")
        }
        let root = try main.volume(role: "System")
        guard root.identifier == system.system.volume else {
          throw MisoError.invalid("System volume identity changed")
        }
        try journal.run(
          "verify-signed-seal",
          NativeCommand(
            .checkSeal, arguments: ["-I", signedRoot.path, "/dev/" + root.device], timeout: 3600))
        return Dictionary(uniqueKeysWithValues: state.map { ($0.key.rawValue, $0.value) })
      }
      let result = Receipt(
        profile: system.profile, preparedJournal: inputs.journalRecord,
        sourceJournal: sourceReceipt,
        disk: try Artifacts.record(destination, relativeTo: journal.output), system: system.system,
        volumeGroup: identifiers.0, containers: containers, layout: system.layout)
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("volumes.json"))
      return result
    }
  }

  static func validateLayout(_ layout: DiskLayout) throws {
    guard layout.partitions.count == 3 else {
      throw MisoError.invalid("Unexpected partition count")
    }
    let expected = try DiskLayout(
      diskBytes: layout.size, sourceBytes: layout.sourceSystemBytes,
      identifiers: [layout.identifier] + layout.partitions.map(\.identifier))
    guard try JSON.encode(layout) == JSON.encode(expected) else {
      throw MisoError.invalid("Invalid source partition layout")
    }
  }

  static func kind(_ hint: String?) -> Kind? {
    switch hint?.uppercased() {
    case "APPLE_APFS", DiskLayout.apfsType.uuidString: return .main
    case "APPLE_APFS_ISC", DiskLayout.iscType.uuidString: return .isc
    case "APPLE_APFS_RECOVERY", DiskLayout.recoveryType.uuidString: return .recovery
    default: return nil
    }
  }

  static func select(_ session: DiskImageSession) throws -> [Kind: APFSTopology.Container] {
    let containers = try session.containers()
    guard let attachment = session.attachment else {
      throw MisoError.invalid("Missing image attachment")
    }
    var result: [Kind: APFSTopology.Container] = [:]
    for container in containers {
      guard let store = container.stores.first,
        let entity = attachment.entities.first(where: { $0.device == "/dev/" + store.device }),
        let kind = kind(entity.contentHint), result[kind] == nil
      else { throw MisoError.invalid("Unrecognized or duplicate container kind") }
      result[kind] = container
    }
    return result
  }

  static func emptyPartition(
    _ kind: Kind, layout: DiskLayout, session: DiskImageSession, journal: ExecutionJournal
  ) throws -> String {
    let state = try select(session)
    guard state[kind] == nil, let attachment = session.attachment, kind != .main else {
      throw MisoError.invalid("Refusing to format an existing container")
    }
    let partition = layout.partitions[kind == .isc ? 0 : 2]
    let nodes = attachment.entities.filter { Self.kind($0.contentHint) == kind }
    guard nodes.count == 1, let node = nodes.first else {
      throw MisoError.invalid("Missing reserved partition")
    }
    let info = try journal.plist(
      PartitionInfo.self, name: "inspect-empty-" + kind.rawValue,
      command: NativeCommand(.disks, arguments: ["info", "-plist", node.device]))
    let whole = try attachment.wholeDevice(requireGPT: true)
    guard info.identifier == partition.identifier, info.offset == partition.offset,
      info.size == partition.size,
      info.parent == String(whole.dropFirst(5)), node.device.hasPrefix(whole + "s")
    else {
      throw MisoError.invalid("Reserved partition identity or geometry mismatch")
    }
    let input = try SafeFile.openRegular(session.image)
    defer { try? input.close() }
    try input.seek(toOffset: partition.offset)
    var remaining = partition.size
    while remaining > 0 {
      try journal.cancellation.check()
      try autoreleasepool {
        let data = try input.readExactly(Int(min(remaining, 8 << 20)))
        guard data.allSatisfy({ $0 == 0 }) else {
          throw MisoError.invalid("Reserved partition is not empty")
        }
        remaining -= UInt64(data.count)
      }
    }
    return node.device
  }

  static func verifyRoles(_ state: [Kind: APFSTopology.Container]) throws {
    guard Set(state.keys) == Set(Kind.allCases) else {
      throw MisoError.invalid("Missing support containers")
    }
    for (kind, container) in state {
      let roles = container.volumes.flatMap(\.roles)
      guard roles.count == container.volumes.count, Set(roles).count == roles.count,
        Set(roles) == expectedRoles[kind]
      else { throw MisoError.invalid("Unexpected final volume roles") }
    }
  }

  static func verifyGroups(_ report: Groups, container: UUID, system: UUID, data: UUID) throws {
    guard report.containers.count == 1, let selected = report.containers.first,
      selected.identifier == container,
      selected.groups.count == 1, let group = selected.groups.first, group.identifier == data,
      group.volumes.count == 2, Set(group.volumes.map(\.role)) == ["System", "Data"],
      group.volumes.first(where: { $0.role == "System" })?.identifier == system,
      group.volumes.first(where: { $0.role == "Data" })?.identifier == data
    else { throw MisoError.invalid("System/Data volume group mismatch") }
  }
}

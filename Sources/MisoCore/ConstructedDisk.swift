import Foundation

protocol ConstructedDiskReceipt: Codable {
  var disk: ImageBundle.FileRecord { get }
  var volumes: VolumeConstruction.Receipt { get }
}

extension VolumeConstruction.Receipt: ConstructedDiskReceipt {
  var volumes: Self { self }
}

extension DataConstruction.Receipt: ConstructedDiskReceipt {}

struct ConstructedDisk<Value: ConstructedDiskReceipt> {
  let receipt: Value
  let source: URL
  let journalRecord: ImageBundle.FileRecord

  init(directory: URL, operation: String, inputs: PreparedInputs, cancellation: CancellationToken?)
    throws
  {
    guard directory.path == directory.resolvingSymlinksInPath().path else {
      throw MisoError.invalid("Source stage path must be canonical")
    }
    let path = directory.appendingPathComponent("journal.json")
    let journal = try JSON.read(ExecutionJournal.Record.self, from: path)
    guard journal.schemaVersion == 1, journal.operation == operation, journal.status == .complete,
      !journal.vmStarted, let result = journal.result
    else { throw MisoError.invalid("A completed \(operation) stage is required") }
    receipt = try JSONDecoder().decode(Value.self, from: JSON.encode(result))
    guard receipt.volumes.profile == inputs.receipt.profile,
      receipt.volumes.preparedJournal == inputs.journalRecord
    else { throw MisoError.invalid("Source stage belongs to different prepared inputs") }
    try VolumeConstruction.validateLayout(receipt.volumes.layout)
    journalRecord = try Artifacts.record(path, relativeTo: directory)
    source = try Artifacts.resolve(receipt.disk, under: directory, cancellation: cancellation)
  }

  func clone(journal: ExecutionJournal, destination requestedDestination: URL? = nil) throws
    -> DiskImageSession
  {
    try journal.setMetadata("target", value: receipt.volumes.profile.release)
    try journal.setMetadata("sourceJournal", value: journalRecord)
    let session = try DiskImageSession(image: source, readOnly: true, journal: journal)
    try session.requireDetached()
    let destination = requestedDestination ?? journal.output.appendingPathComponent("disk.img")
    guard destination.path.hasPrefix(journal.output.path + "/") else {
      throw MisoError.invalid("Clone destination must belong to the current operation")
    }
    try Artifacts.clone(source, to: destination)
    guard try SafeFile.sha256(destination) == receipt.disk.sha256 else {
      throw MisoError.invalid("Source stage clone digest mismatch")
    }
    return try DiskImageSession(image: destination, readOnly: false, journal: journal)
  }
}

enum ImageChecks {
  static func layout(
    _ session: DiskImageSession, volumes: VolumeConstruction.Receipt, journal: ExecutionJournal
  ) throws -> [VolumeConstruction.Kind: APFSTopology.Container] {
    let state = try VolumeConstruction.select(session)
    try VolumeConstruction.verifyRoles(state)
    for kind in VolumeConstruction.Kind.allCases {
      guard let expected = volumes.containers[kind.rawValue], let actual = state[kind],
        expected.identifier == actual.identifier,
        Set(expected.volumes.map(\.identifier)) == Set(actual.volumes.map(\.identifier)),
        expected.volumes.allSatisfy({ previous in
          actual.volumes.contains {
            $0.identifier == previous.identifier && $0.roles == previous.roles
          }
        })
      else { throw MisoError.invalid("Source volume identity changed") }
    }
    guard let main = state[.main], main.identifier == volumes.system.container,
      try main.volume(role: "System").identifier == volumes.system.volume,
      try main.volume(role: "Data").identifier == volumes.volumeGroup
    else { throw MisoError.invalid("System volume group changed") }
    let groups = try journal.plist(
      VolumeConstruction.Groups.self, name: "verify-volume-group",
      command: NativeCommand(
        .disks, arguments: ["apfs", "listVolumeGroups", main.device, "-plist"]))
    try VolumeConstruction.verifyGroups(
      groups, container: main.identifier, system: volumes.system.volume, data: volumes.volumeGroup)
    return state
  }

  static func filesystems(
    _ session: DiskImageSession, volumes: VolumeConstruction.Receipt, inputs: PreparedInputs,
    journal: ExecutionJournal
  ) throws {
    let fsck = try inputs.file("fsck_apfs", cancellation: journal.cancellation)
    let signedRoot = try inputs.file("signed-system-root", cancellation: journal.cancellation)
    guard let checker = inputs.receipt.tools["fsck_apfs"] else {
      throw MisoError.invalid("Missing APFS checker")
    }
    try session.withAttachment { session in
      let state = try layout(session, volumes: volumes, journal: journal)
      for kind in VolumeConstruction.Kind.allCases {
        guard let container = state[kind] else { throw MisoError.invalid("Missing container") }
        try session.verifyOwnership()
        try journal.run(
          "check-" + kind.rawValue,
          NativeCommand.restoreTool(
            fsck, sha256: checker.sha256, arguments: ["-n", "/dev/r" + container.device]))
      }
      guard let main = state[.main] else { throw MisoError.invalid("Missing main container") }
      try journal.run(
        "verify-signed-seal",
        NativeCommand(
          .checkSeal,
          arguments: ["-I", signedRoot.path, "/dev/" + main.volume(role: "System").device],
          timeout: 3600))
    }
  }
}

import Darwin
import Foundation

public enum SystemConstruction {
  public struct Receipt: Codable, Sendable {
    public let profile: RestoreProfile
    public let preparedJournal: ImageBundle.FileRecord
    public let disk: ImageBundle.FileRecord
    public let layout: DiskLayout
    public let system: SystemIdentity
  }

  public struct SystemIdentity: Codable, Sendable {
    public let container: UUID
    public let volume: UUID
    public let snapshotName: String
    public let snapshot: UUID
  }

  struct VolumeInfo: Decodable {
    let identifier: UUID
    let sealed: String?
    enum CodingKeys: String, CodingKey {
      case identifier = "VolumeUUID"
      case sealed = "Sealed"
    }
  }

  struct Snapshots: Decodable {
    struct Snapshot: Decodable {
      let identifier: UUID
      let name: String
      let root: Bool?
      enum CodingKeys: String, CodingKey {
        case identifier = "SnapshotUUID"
        case name = "SnapshotName"
        case root = "RootTo"
      }
    }
    let snapshots: [Snapshot]
    enum CodingKeys: String, CodingKey { case snapshots = "Snapshots" }
  }

  public static func run(
    prepared: URL, output: URL, diskBytes: UInt64 = 40 << 30,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("System construction requires administrator privileges")
    }
    guard diskBytes <= 1 << 40 else { throw MisoError.invalid("Disk size exceeds limit") }
    let inputs = try PreparedInputs(prepared)
    let journal = try ExecutionJournal(
      output: output, operation: "seal-system", cancellation: cancellation)
    return try journal.perform {
      guard journal.record.host.architecture == "arm64" else {
        throw MisoError.unsupported("System construction requires Apple silicon")
      }
      try journal.setMetadata("target", value: inputs.receipt.profile.release)
      try journal.setMetadata("preparedJournal", value: inputs.journalRecord)
      try journal.setMetadata("stage", value: "verify-prepared-inputs")
      let source = try inputs.file("OS", cancellation: journal.cancellation)
      let root = try inputs.component("SystemVolume", cancellation: journal.cancellation)
      let remap = try inputs.file("timestamp-remap", cancellation: journal.cancellation)
      let signedRoot = try inputs.file("signed-system-root", cancellation: journal.cancellation)
      let sealTool = try RestoreTool.prepare("apfs_sealvolume", inputs: inputs, journal: journal)
      let fsck = try RestoreTool.prepare("fsck_apfs", inputs: inputs, journal: journal)
      guard let sourceRecord = inputs.receipt.derived["OS"]
      else {
        throw MisoError.invalid("Missing System source or tool record")
      }
      _ = try DiskLayout(diskBytes: diskBytes, sourceBytes: sourceRecord.bytes)
      try Artifacts.requireSpace(sourceRecord.bytes + (8 << 30), at: journal.output)
      let disk = journal.output.appendingPathComponent("disk.img")
      try journal.setMetadata("stage", value: "seed-disk")
      let layout = try DiskLayout.create(
        source: source, output: disk, diskBytes: diskBytes,
        expectedSHA256: sourceRecord.sha256, cancellation: journal.cancellation)
      try SafeFile.writeNew(
        JSON.encode(layout), to: journal.output.appendingPathComponent("initial-layout.json"))
      let session = try DiskImageSession(image: disk, readOnly: false, journal: journal)
      let sealed = try session.withAttachment { session in
        let containers = try session.containers()
        guard containers.count == 1, let container = containers.first, container.volumes.count == 1
        else {
          throw MisoError.invalid("Expected one source APFS container and System volume")
        }
        let system = try container.volume(role: "System")
        guard system.mountPoint == nil else {
          throw MisoError.invalid("System source must be unmounted")
        }
        try journal.run(
          "grow-system",
          NativeCommand(
            .disks, arguments: ["apfs", "resizeContainer", container.device, "0"], timeout: 600))
        try session.verifyOwnership()
        try journal.setMetadata("stage", value: "seal-system")
        try journal.run(
          "seal-system",
          sealTool.command(
            arguments: [
              "-T", "-H", "sha256", "-I", root.path, "-P", "-R", remap.path, "-y", "-r", "-s",
              inputs.receipt.snapshotName, "/dev/" + system.device,
            ]))
        try session.verifyOwnership()
        try journal.run(
          "verify-signed-seal",
          NativeCommand(
            .checkSeal, arguments: ["-I", signedRoot.path, "/dev/" + system.device], timeout: 3600))
        try journal.run(
          "check-system-apfs",
          fsck.command(arguments: ["-n", "/dev/r" + container.device]))
        let updated = try systemVolume(in: session.containers(), container: container.identifier)
        guard updated.device == system.device else {
          throw MisoError.invalid("System device changed during sealing")
        }
        try journal.setMetadata("systemUUIDBeforeSeal", value: system.identifier)
        return (container: container.identifier, volume: updated.identifier)
      }
      try journal.setMetadata("stage", value: "audit-sealed-system")
      let audit = try DiskImageSession(image: disk, readOnly: true, journal: journal)
      let identity = try audit.withAttachment { session in
        let system = try systemVolume(
          in: session.containers(), container: sealed.container, volume: sealed.volume)
        _ = try ImageMounts.mount(
          system, session: session, journal: journal, name: "sealed-system", readOnly: true)
        let info = try journal.plist(
          VolumeInfo.self, name: "inspect-system",
          command: NativeCommand(.disks, arguments: ["info", "-plist", system.device]))
        let snapshots = try journal.plist(
          Snapshots.self, name: "inspect-snapshots",
          command: NativeCommand(
            .disks, arguments: ["apfs", "listSnapshots", system.device, "-plist"]))
        _ = try systemVolume(
          in: session.containers(), container: sealed.container, volume: sealed.volume)
        return try verify(
          info: info, snapshots: snapshots, container: sealed.container,
          volume: sealed.volume, expectedName: inputs.receipt.snapshotName)
      }
      try journal.setMetadata("stage", value: "hash-sealed-disk")
      let result = Receipt(
        profile: inputs.receipt.profile, preparedJournal: inputs.journalRecord,
        disk: try Artifacts.record(disk, relativeTo: journal.output), layout: layout,
        system: identity)
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("system.json"))
      return result
    }
  }

  static func systemVolume(
    in containers: [APFSTopology.Container], container: UUID, volume: UUID? = nil
  ) throws -> APFSTopology.Volume {
    guard containers.count == 1, let current = containers.first,
      current.identifier == container, current.volumes.count == 1
    else { throw MisoError.invalid("System container identity or volume count changed") }
    let system = try current.volume(role: "System")
    guard volume == nil || system.identifier == volume else {
      throw MisoError.invalid("System volume identity changed")
    }
    return system
  }

  static func verify(
    info: VolumeInfo, snapshots: Snapshots, container: UUID, volume: UUID, expectedName: String
  ) throws -> SystemIdentity {
    let roots = snapshots.snapshots.filter { $0.root == true }
    guard info.sealed == "Yes", info.identifier == volume, roots.count == 1, let root = roots.first,
      root.name == expectedName
    else {
      throw MisoError.invalid("Sealed System identity or selected root snapshot mismatch")
    }
    return SystemIdentity(
      container: container, volume: volume, snapshotName: root.name, snapshot: root.identifier)
  }
}

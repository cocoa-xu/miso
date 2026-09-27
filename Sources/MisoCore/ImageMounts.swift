import Darwin
import Foundation

enum ImageMounts {
  struct Info: Decodable {
    let identifier: UUID
    let mountPoint: String
    let ownership: Bool
    enum CodingKeys: String, CodingKey {
      case identifier = "VolumeUUID"
      case mountPoint = "MountPoint"
      case ownership = "GlobalPermissionsEnabled"
    }
  }
  static func mount(
    _ volume: APFSTopology.Volume, session: DiskImageSession, journal: ExecutionJournal,
    name: String, readOnly: Bool
  ) throws -> GuestVolume {
    guard
      try session.containers().flatMap(\.volumes).contains(where: {
        $0.identifier == volume.identifier && $0.device == volume.device
      }), readOnly || !session.readOnly
    else {
      throw MisoError.invalid("Volume is not an unmounted owned image volume")
    }
    try verifyAttachment(session.attachment, volume: volume, mountPoint: nil)
    let mount = journal.output.appendingPathComponent(
      "mount-\(name)-\(journal.record.commands.count)")
    try SafeFile.makeDirectory(mount)
    let options = readOnly ? ["readOnly"] : []
    try journal.run(
      "mount-" + name,
      NativeCommand(
        .disks, arguments: ["mount"] + options + ["-mountPoint", mount.path, volume.device]))
    guard
      try session.containers().flatMap(\.volumes).contains(where: {
        $0.identifier == volume.identifier && $0.device == volume.device
      })
    else { throw MisoError.invalid("Image volume mounted at an unexpected location") }
    try verifyAttachment(session.attachment, volume: volume, mountPoint: mount.path)
    var filesystem = statfs()
    guard statfs(mount.path, &filesystem) == 0,
      (filesystem.f_flags & UInt32(MNT_RDONLY) != 0) == readOnly
    else { throw MisoError.invalid("Image mount permissions differ from requested access") }
    try session.verifyOwnership()
    try journal.run(
      "ownership-" + name, NativeCommand(.disks, arguments: ["enableOwnership", volume.device]))
    let info = try journal.plist(
      Info.self, name: "mount-info-" + name,
      command: NativeCommand(.disks, arguments: ["info", "-plist", volume.device]))
    guard info.identifier == volume.identifier, info.mountPoint == mount.path, info.ownership else {
      throw MisoError.invalid("Mounted volume ownership is not enabled")
    }
    return try GuestVolume(mount)
  }

  static func verifyAttachment(
    _ attachment: DiskImageAttachment?, volume: APFSTopology.Volume, mountPoint: String?
  ) throws {
    let entries = attachment?.entities.filter { $0.device == "/dev/" + volume.device } ?? []
    guard entries.count == 1, entries[0].mountPoint == mountPoint else {
      throw MisoError.invalid("Owned image volume mount point mismatch")
    }
  }
}

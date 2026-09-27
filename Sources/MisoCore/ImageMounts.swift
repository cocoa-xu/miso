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
    name: String, readOnly: Bool, at requestedMount: URL? = nil, restricted: Bool = false
  ) throws -> GuestVolume {
    guard
      try session.containers().flatMap(\.volumes).contains(where: {
        $0.identifier == volume.identifier && $0.device == volume.device
      }), readOnly || !session.readOnly
    else {
      throw MisoError.invalid("Volume is not an unmounted owned image volume")
    }
    try verifyAttachment(session.attachment, volume: volume, mountPoint: nil)
    let mount =
      requestedMount
      ?? journal.output.appendingPathComponent(
        "mount-\(name)-\(journal.record.commands.count)")
    guard mount.path.hasPrefix(journal.output.path + "/"),
      mount.path == mount.standardizedFileURL.path,
      mount.path == mount.resolvingSymlinksInPath().path
    else { throw MisoError.invalid("Unsafe owned mount point") }
    if requestedMount == nil { try SafeFile.makeDirectory(mount) }
    _ = try GuestVolume(mount)
    guard try FileManager.default.contentsOfDirectory(atPath: mount.path).isEmpty else {
      throw MisoError.invalid("Mount point must be empty")
    }
    let options = readOnly ? ["readOnly"] : []
    let command =
      try restricted
      ? NativeCommand(
        .mountAPFS,
        arguments: [
          "-o", readOnly ? "rdonly,nobrowse,nosuid" : "nobrowse,nosuid",
          "/dev/" + volume.device, mount.path,
        ])
      : NativeCommand(
        .disks, arguments: ["mount"] + options + ["-mountPoint", mount.path, volume.device])
    try journal.run(
      "mount-" + name, command)
    guard
      try session.containers().flatMap(\.volumes).contains(where: {
        $0.identifier == volume.identifier && $0.device == volume.device
      })
    else { throw MisoError.invalid("Image volume mounted at an unexpected location") }
    try verifyAttachment(session.attachment, volume: volume, mountPoint: mount.path)
    var filesystem = statfs()
    guard statfs(mount.path, &filesystem) == 0,
      (filesystem.f_flags & UInt32(MNT_RDONLY) != 0) == readOnly,
      !restricted || filesystem.f_flags & UInt32(MNT_NOSUID) != 0
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

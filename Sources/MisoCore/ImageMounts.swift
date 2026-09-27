import Darwin
import Foundation

enum ImageMounts {
  static func mount(
    _ volume: APFSTopology.Volume, session: DiskImageSession, journal: ExecutionJournal,
    name: String, readOnly: Bool
  ) throws -> GuestVolume {
    guard
      try session.containers().flatMap(\.volumes).contains(where: {
        $0.identifier == volume.identifier && $0.device == volume.device && $0.mountPoint == nil
      }), readOnly || !session.readOnly
    else {
      throw MisoError.invalid("Volume is not an unmounted owned image volume")
    }
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
          && $0.mountPoint == mount.path
      })
    else { throw MisoError.invalid("Image volume mounted at an unexpected location") }
    var filesystem = statfs()
    guard statfs(mount.path, &filesystem) == 0,
      (filesystem.f_flags & UInt32(MNT_RDONLY) != 0) == readOnly
    else { throw MisoError.invalid("Image mount permissions differ from requested access") }
    try session.verifyOwnership()
    try journal.run(
      "ownership-" + name, NativeCommand(.disks, arguments: ["enableOwnership", volume.device]))
    return try GuestVolume(mount)
  }
}

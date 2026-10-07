import Darwin
import Foundation

enum ImageMounts {
  struct SystemOverlay {
    let volume: APFSTopology.Volume
    let root: URL

    func validate(
      mount: URL, role: [String], mountedFrom: String, mountedAt: String,
      flags: UInt32, restricted: Bool
    ) throws {
      guard volume.roles == ["System"], role == ["Data"] || role == ["Preboot"],
        mount.path == root.appendingPathComponent("System/Volumes/" + role[0]).path,
        mountedFrom == "/dev/" + volume.device, mountedAt == root.path,
        flags & UInt32(MNT_RDONLY | MNT_NOSUID) == UInt32(MNT_RDONLY | MNT_NOSUID),
        restricted
      else { throw MisoError.invalid("Overlay must cover an owned read-only System directory") }
    }
  }

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
    name: String, readOnly: Bool, at requestedMount: URL? = nil, restricted: Bool = false,
    systemOverlay: SystemOverlay? = nil
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
      mount.path == mount.standardized.path
    else { throw MisoError.invalid("Unsafe owned mount point") }
    if requestedMount == nil { try SafeFile.makeDirectory(mount) }
    _ = try GuestVolume(mount)
    if let systemOverlay {
      try verifyAttachment(
        session.attachment, volume: systemOverlay.volume, mountPoint: systemOverlay.root.path)
      var info = statfs()
      guard statfs(mount.path, &info) == 0 else {
        throw MisoError.system("Inspect System overlay", errno)
      }
      let mountedFrom = withUnsafePointer(to: &info.f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      let mountedAt = withUnsafePointer(to: &info.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      try systemOverlay.validate(
        mount: mount, role: volume.roles, mountedFrom: mountedFrom, mountedAt: mountedAt,
        flags: info.f_flags, restricted: restricted)
    } else if try !FileManager.default.contentsOfDirectory(atPath: mount.path).isEmpty {
      throw MisoError.invalid("Mount point must be empty: \(mount.path)")
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
    try waitForAttachment(
      volume: volume, mountPoint: mount.path,
      refresh: {
        try session.verifyOwnership()
        return session.attachment
      })
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
      let observed = entries.map { $0.mountPoint ?? "<unmounted>" }.joined(separator: ", ")
      throw MisoError.invalid(
        "Owned image volume \(volume.device) mount point mismatch: expected "
          + "\(mountPoint ?? "<unmounted>"), observed \(entries.count) entries [\(observed)]")
    }
  }

  static func waitForAttachment(
    volume: APFSTopology.Volume, mountPoint: String,
    refresh: () throws -> DiskImageAttachment?,
    pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
  ) throws {
    for attempt in 0..<10 {
      let attachment = try refresh()
      guard let attachment else { throw MisoError.invalid("Owned image disappeared after mount") }
      let entries = attachment.entities.filter { $0.device == "/dev/" + volume.device }
      let pending = entries.isEmpty || (entries.count == 1 && entries[0].mountPoint == nil)
      if !pending || attempt == 9 {
        try verifyAttachment(attachment, volume: volume, mountPoint: mountPoint)
        return
      }
      if attempt == 0 {
        BuildProgress.write("Waiting for mount metadata: \(volume.device) at \(mountPoint)")
      }
      pause()
    }
  }
}

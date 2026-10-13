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
    try verifyMounts(mounts(), volume: volume, mountPoint: nil)
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
      try verifyMounts(
        mounts(), volume: systemOverlay.volume, mountPoint: systemOverlay.root.path)
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
    try waitForMount(
      volume: volume, mountPoint: mount.path,
      refresh: {
        try session.verifyOwnership()
        return try mounts()
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

  struct Mount {
    let device: String
    let path: String
  }

  static func mounts() throws -> [Mount] {
    var buffer: UnsafeMutablePointer<statfs>?
    let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
    guard count > 0, let buffer else { throw MisoError.system("Read mounted filesystems", errno) }
    defer { free(buffer) }
    return (0..<Int(count)).map { index in
      let device = withUnsafePointer(to: &buffer[index].f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      let path = withUnsafePointer(to: &buffer[index].f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      return Mount(device: device, path: path)
    }
  }

  static func verifyMounts(
    _ mounts: [Mount], volume: APFSTopology.Volume, mountPoint: String?
  ) throws {
    let entries = mounts.filter { $0.device == "/dev/" + volume.device }
    let expected = mountPoint.map { [$0] } ?? []
    guard entries.map(\.path) == expected else {
      let observed = entries.map(\.path).joined(separator: ", ")
      throw MisoError.invalid(
        "Owned image volume \(volume.device) mount point mismatch: expected "
          + "\(mountPoint ?? "<unmounted>"), observed \(entries.count) entries [\(observed)]")
    }
  }

  static func waitForMount(
    volume: APFSTopology.Volume, mountPoint: String,
    refresh: () throws -> [Mount],
    pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
  ) throws {
    for attempt in 0..<10 {
      let current = try refresh()
      let entries = current.filter { $0.device == "/dev/" + volume.device }
      if !entries.isEmpty || attempt == 9 {
        try verifyMounts(current, volume: volume, mountPoint: mountPoint)
        return
      }
      if attempt == 0 {
        BuildProgress.write("Waiting for mount metadata: \(volume.device) at \(mountPoint)")
      }
      pause()
    }
  }
}

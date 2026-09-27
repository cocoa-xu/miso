import Darwin
import Foundation

enum BootInstallation {
  static let targets: [(String, VolumeConstruction.Kind, String)] = [
    ("Preboot", .main, "Preboot"), ("iSCPreboot", .isc, "Preboot"),
    ("PairedRecovery", .main, "Recovery"), ("SystemRecovery", .recovery, "Recovery"),
  ]

  static func mounts(
    session: DiskImageSession, volumes: VolumeConstruction.Receipt, journal: ExecutionJournal,
    readOnly: Bool
  ) throws -> [String: GuestVolume] {
    let state = try ImageChecks.layout(session, volumes: volumes, journal: journal)
    var mounts: [String: GuestVolume] = [:]
    for (name, kind, role) in targets {
      guard let container = state[kind] else {
        throw MisoError.invalid("Missing support container")
      }
      let volume = try container.volume(role: role)
      guard volume.encrypted == false else { throw MisoError.invalid("Encrypted support volume") }
      mounts[name] = try ImageMounts.mount(
        volume, session: session, journal: journal, name: name.lowercased(), readOnly: readOnly)
    }
    return mounts
  }

  static func destination(_ path: String, mounts: [String: GuestVolume], allowLink: Bool = false)
    throws -> URL
  {
    let parts = try SafeFile.relativePath(path).split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, let volume = mounts[parts[0]] else {
      throw MisoError.invalid("Invalid boot destination")
    }
    return try volume.path(parts[1], allowLeafLink: allowLink)
  }

  static func install(
    _ boot: BootPersonalization.Receipt, source: URL, mounts: [String: GuestVolume],
    cancellation: CancellationToken
  ) throws {
    for relative in boot.directories {
      if mounts[relative] != nil { continue }
      let path = try destination(relative, mounts: mounts)
      guard mkdir(path.path, 0o755) == 0, chown(path.path, 0, 0) == 0 else {
        throw MisoError.system("Create fresh boot directory", errno)
      }
    }
    for record in boot.files {
      try cancellation.check()
      let origin = try Artifacts.resolve(record, under: source, cancellation: cancellation)
      let target = try destination(record.path, mounts: mounts)
      try Artifacts.copy(origin, to: target, maximumBytes: record.bytes, cancellation: cancellation)
      guard chown(target.path, 0, 0) == 0, chmod(target.path, 0o644) == 0 else {
        throw MisoError.system("Set boot file metadata", errno)
      }
    }
    for link in boot.links {
      _ = try SafeFile.relativePath(link.target)
      let path = try destination(link.path, mounts: mounts)
      guard symlink(link.target, path.path) == 0, lchown(path.path, 0, 0) == 0 else {
        throw MisoError.system("Create boot link", errno)
      }
    }
    let clone = try destination(boot.requiredClone, mounts: mounts)
    try Artifacts.clone(
      clone.deletingLastPathComponent().appendingPathComponent("os.dmg"), to: clone)
  }

  static func verify(
    _ boot: BootPersonalization.Receipt, mounts: [String: GuestVolume],
    cancellation: CancellationToken
  ) throws {
    for relative in boot.directories {
      let path = try mounts[relative]?.root ?? destination(relative, mounts: mounts)
      let info = try FileMetadata.inspect(path)
      guard info.st_mode & S_IFMT == S_IFDIR else {
        throw MisoError.invalid("Missing boot directory")
      }
    }
    for record in boot.files {
      try cancellation.check()
      let path = try destination(record.path, mounts: mounts)
      let info = try FileMetadata.inspect(path)
      guard info.st_mode == S_IFREG | 0o644, info.st_uid == 0, info.st_gid == 0,
        info.st_size == record.bytes, try SafeFile.sha256(path) == record.sha256
      else { throw MisoError.invalid("Installed boot payload mismatch: \(record.path)") }
    }
    for link in boot.links {
      let path = try destination(link.path, mounts: mounts, allowLink: true)
      let rootName = String(link.path.split(separator: "/")[0])
      guard let root = mounts[rootName], try FileMetadata.inspect(path).st_mode & S_IFMT == S_IFLNK,
        try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == link.target,
        path.resolvingSymlinksInPath().path.hasPrefix(root.root.path + "/")
      else { throw MisoError.invalid("Installed recovery link mismatch") }
    }
    let clone = try destination(boot.requiredClone, mounts: mounts)
    let original = clone.deletingLastPathComponent().appendingPathComponent("os.dmg")
    guard try SafeFile.sha256(clone) == SafeFile.sha256(original),
      try FileMetadata.inspect(clone).st_size == FileMetadata.inspect(original).st_size
    else { throw MisoError.invalid("Installed cryptex clone mismatch") }
  }
}

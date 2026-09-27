import Darwin
import Foundation

struct GuestVolume {
  let root: URL
  let device: dev_t

  init(_ root: URL) throws {
    let info = try FileMetadata.inspect(root)
    guard info.st_mode & S_IFMT == S_IFDIR, root.path == root.resolvingSymlinksInPath().path else {
      throw MisoError.invalid("Guest volume root must be a canonical directory")
    }
    self.root = root
    device = info.st_dev
  }

  func path(_ relative: String, createParents: Bool = false, allowLeafLink: Bool = false) throws
    -> URL
  {
    let parts = try SafeFile.relativePath(relative).split(separator: "/")
    var current = root
    for (index, part) in parts.enumerated() {
      current.appendPathComponent(String(part))
      var info = stat()
      let last = index == parts.count - 1
      if lstat(current.path, &info) != 0 {
        guard errno == ENOENT else { throw MisoError.system("Inspect guest path", errno) }
        if last { return current }
        guard createParents, mkdir(current.path, 0o755) == 0 else {
          throw MisoError.invalid("Missing guest parent directory")
        }
        info = try FileMetadata.inspect(current)
      }
      guard info.st_dev == device, (last && allowLeafLink) || info.st_mode & S_IFMT != S_IFLNK,
        last || info.st_mode & S_IFMT == S_IFDIR
      else { throw MisoError.invalid("Guest path crosses a symlink or mount") }
    }
    return current
  }

  func write(_ relative: String, data: Data, uid: uid_t = 0, gid: gid_t = 0, mode: mode_t = 0o644)
    throws
  {
    let target = try path(relative, createParents: true)
    try SafeFile.replace(data, at: target)
    guard chown(target.path, uid, gid) == 0, chmod(target.path, mode) == 0 else {
      throw MisoError.system("Set guest file metadata", errno)
    }
  }

  func contains(_ relative: String) throws -> Bool {
    let parts = try SafeFile.relativePath(relative).split(separator: "/")
    var current = root
    for (index, part) in parts.enumerated() {
      current.appendPathComponent(String(part))
      var info = stat()
      if lstat(current.path, &info) != 0 {
        guard errno == ENOENT else { throw MisoError.system("Inspect guest path", errno) }
        return false
      }
      guard info.st_dev == device, info.st_mode & S_IFMT != S_IFLNK,
        index == parts.count - 1 || info.st_mode & S_IFMT == S_IFDIR
      else { throw MisoError.invalid("Guest path crosses a symlink or mount") }
    }
    return true
  }

  func plist(_ relative: String) throws -> [String: Any] {
    try RestoreInspection.plist(SafeFile.read(path(relative), limit: 16 << 20))
  }

  func mergePlist(
    _ relative: String, values: [String: Any], uid: uid_t = 0, gid: gid_t = 0, mode: mode_t = 0o644
  ) throws {
    let target = try path(relative, createParents: true)
    let original = FileManager.default.fileExists(atPath: target.path) ? try plist(relative) : [:]
    let result = Self.merge(original, values)
    try write(
      relative,
      data: PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0),
      uid: uid, gid: gid, mode: mode)
  }

  static func merge(_ original: [String: Any], _ values: [String: Any]) -> [String: Any] {
    original.merging(values) { old, new in
      if let old = old as? [String: Any], let new = new as? [String: Any] { return merge(old, new) }
      return new
    }
  }
}

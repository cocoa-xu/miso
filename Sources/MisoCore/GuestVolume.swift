import Darwin
import Foundation

struct GuestDirectory {
  let url: URL
  let device: dev_t
  let inode: ino_t

  fileprivate init(_ url: URL, info: stat) {
    self.url = url
    device = info.st_dev
    inode = info.st_ino
  }

  func replace(_ name: String, data: Data, uid: uid_t, gid: gid_t, mode: mode_t) throws {
    guard try SafeFile.relativePath(name) == name, !name.contains("/") else {
      throw MisoError.invalid("Expected a guest file name")
    }
    let parent = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw MisoError.system("Open guest output directory", errno) }
    defer { close(parent) }
    var info = stat()
    guard fstat(parent, &info) == 0, info.st_dev == device, info.st_ino == inode,
      info.st_mode & S_IFMT == S_IFDIR
    else { throw MisoError.invalid("Guest output directory identity changed") }
    if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
      guard info.st_mode & S_IFMT == S_IFREG, info.st_dev == device else {
        throw MisoError.invalid("Refusing to replace a non-regular guest file")
      }
    } else if errno != ENOENT {
      throw MisoError.system("Inspect guest output file", errno)
    }
    let temporary = ".\(UUID().uuidString).tmp"
    let fd = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw MisoError.system("Create guest output file", errno) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      _ = unlinkat(parent, temporary, 0)
    }
    try handle.write(contentsOf: data)
    guard fchown(fd, uid, gid) == 0, fchmod(fd, mode) == 0 else {
      throw MisoError.system("Set guest file metadata", errno)
    }
    try handle.synchronize()
    guard renameat(parent, temporary, parent, name) == 0 else {
      throw MisoError.system("Publish guest output file", errno)
    }
    guard fsync(parent) == 0 else {
      throw MisoError.system("Synchronize guest output directory", errno)
    }
  }
}

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

  func directory(_ relative: String? = nil) throws -> GuestDirectory {
    let url = try relative.map { try path($0) } ?? root
    let info = try FileMetadata.inspect(url)
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == device else {
      throw MisoError.invalid("Directory is outside its guest volume")
    }
    return GuestDirectory(url, info: info)
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

  func makeDirectories(_ relative: String, uid: uid_t = 0, gid: gid_t = 0) throws {
    var current = ""
    for part in try SafeFile.relativePath(relative).split(separator: "/") {
      current += (current.isEmpty ? "" : "/") + part
      if !(try contains(current)) {
        let url = try path(current)
        try SafeFile.makeDirectory(url)
        guard chown(url.path, uid, gid) == 0, chmod(url.path, 0o755) == 0 else {
          throw MisoError.system("Set guest directory metadata", errno)
        }
      }
      _ = try directory(current)
    }
  }

  func write(_ relative: String, data: Data, uid: uid_t = 0, gid: gid_t = 0, mode: mode_t = 0o644)
    throws
  {
    let target = try path(relative, createParents: true)
    let parent = relative.split(separator: "/").dropLast().joined(separator: "/")
    try directory(parent.isEmpty ? nil : parent).replace(
      target.lastPathComponent, data: data, uid: uid, gid: gid, mode: mode)
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

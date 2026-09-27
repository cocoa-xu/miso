import Darwin
import Foundation
import MisoSystem

enum FileMetadata {
  static let xattrOptions = XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION

  static func attributes(_ path: URL, ignoringCompression: Bool) throws -> [String: Data] {
    let length = listxattr(path.path, nil, 0, xattrOptions)
    guard length >= 0, length <= 1 << 20 else {
      throw MisoError.system("List extended attributes", errno)
    }
    var names = [CChar](repeating: 0, count: max(1, length))
    guard listxattr(path.path, &names, length, xattrOptions) == length else {
      throw MisoError.invalid("Extended attribute names changed")
    }
    let data = Data(names.prefix(length).map { UInt8(bitPattern: $0) })
    var result: [String: Data] = [:]
    for bytes in data.split(separator: 0) {
      guard let name = String(data: Data(bytes), encoding: .utf8) else {
        throw MisoError.invalid("Invalid extended attribute name")
      }
      if ignoringCompression && ["com.apple.decmpfs", "com.apple.ResourceFork"].contains(name) {
        continue
      }
      let size = getxattr(path.path, name, nil, 0, 0, xattrOptions)
      guard size >= 0, size <= 64 << 20 else {
        throw MisoError.system("Read extended attribute size", errno)
      }
      var value = Data(count: size)
      let count = value.withUnsafeMutableBytes {
        getxattr(path.path, name, $0.baseAddress, size, 0, xattrOptions)
      }
      guard count == size else { throw MisoError.invalid("Extended attribute changed") }
      result[name] = value
    }
    return result
  }

  static func acl(_ path: URL) throws -> Data? {
    guard let value = acl_get_link_np(path.path, ACL_TYPE_EXTENDED) else {
      if errno == ENOENT {
        _ = try inspect(path)
        return nil
      }
      throw MisoError.system("Read ACL", errno)
    }
    defer { acl_free(UnsafeMutableRawPointer(value)) }
    var count = 0
    guard let text = acl_to_text(value, &count), count >= 0, count <= 1 << 20 else {
      throw MisoError.system("Serialize ACL", errno)
    }
    defer { acl_free(text) }
    return Data(bytes: text, count: count)
  }

  static func inspect(_ path: URL) throws -> stat {
    var info = stat()
    guard lstat(path.path, &info) == 0 else {
      throw MisoError.system("Inspect file metadata", errno)
    }
    return info
  }

  static func equivalent(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid && lhs.st_mode == rhs.st_mode
      && lhs.st_flags & ~UInt32(UF_COMPRESSED) == rhs.st_flags & ~UInt32(UF_COMPRESSED)
  }

  static func repair(_ path: URL, expected: stat) throws {
    var actual = try inspect(path)
    if actual.st_uid != expected.st_uid || actual.st_gid != expected.st_gid {
      guard lchown(path.path, expected.st_uid, expected.st_gid) == 0 else {
        throw MisoError.system("Restore file ownership", errno)
      }
      actual = try inspect(path)
    }
    if actual.st_mode != expected.st_mode {
      guard lchmod(path.path, expected.st_mode & 0o7777) == 0 else {
        throw MisoError.system("Restore file mode", errno)
      }
    }
    actual = try inspect(path)
    let flags =
      (expected.st_flags & ~UInt32(UF_COMPRESSED)) | (actual.st_flags & UInt32(UF_COMPRESSED))
    if flags != actual.st_flags {
      guard lchflags(path.path, flags) == 0 else {
        throw MisoError.system("Restore file flags", errno)
      }
    }
  }

  static func restoreAttributes(_ source: URL, to destination: URL, ignoringCompression: Bool)
    throws -> Bool
  {
    let hostAttribute = "com.apple.provenance"
    var expected = try attributes(source, ignoringCompression: ignoringCompression)
    var actual = try attributes(destination, ignoringCompression: ignoringCompression)
    expected.removeValue(forKey: hostAttribute)
    let hostProvenance = actual.removeValue(forKey: hostAttribute) != nil
    let unexpected = Set(actual.keys).subtracting(expected.keys)
    guard unexpected.isEmpty else {
      throw MisoError.invalid(
        "Unexpected copied attributes at \(destination.path): \(unexpected.sorted())")
    }
    for (name, value) in expected where actual[name] != value {
      let status = value.withUnsafeBytes {
        setxattr(destination.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
      }
      guard status == 0 else { throw MisoError.system("Restore extended attribute", errno) }
    }
    let verified = try attributes(destination, ignoringCompression: ignoringCompression)
      .filter { $0.key != hostAttribute }
    guard expected == verified else {
      throw MisoError.invalid("Copied extended attribute verification failed")
    }
    return hostProvenance
  }

  static func copyTree(
    _ source: GuestDirectory, to destination: GuestDirectory, cancellation: CancellationToken? = nil
  )
    throws
  {
    let origin = source.url.resolvingSymlinksInPath().path
    let target = destination.url.resolvingSymlinksInPath().path
    let sourceInfo = try inspect(source.url)
    let destinationInfo = try inspect(destination.url)
    guard !target.hasPrefix(origin + "/"), origin != target,
      sourceInfo.st_mode & S_IFMT == S_IFDIR, destinationInfo.st_mode & S_IFMT == S_IFDIR,
      sourceInfo.st_dev == source.device, sourceInfo.st_ino == source.inode,
      destinationInfo.st_dev == destination.device, destinationInfo.st_ino == destination.inode,
      sourceInfo.st_dev != destinationInfo.st_dev || sourceInfo.st_ino != destinationInfo.st_ino
    else {
      throw MisoError.invalid("Invalid template copy roots")
    }
    let status = miso_copy_tree(source.url.path + "/", destination.url.path, cancellation?.storage)
    guard status == 0 else { throw MisoError.system("Copy template tree", status) }
    try cancellation?.check()
  }

  static func walk(_ root: URL, body: (String, stat) throws -> Void) throws {
    let device = try inspect(root).st_dev
    var pending = [String]()
    pending.append("")
    var count = 0
    while let relative = pending.popLast() {
      let directory = root.appendingPathComponent(relative)
      for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
        count += 1
        guard count <= 2_000_000 else {
          throw MisoError.invalid("Template entry count exceeds limit")
        }
        let child = relative.isEmpty ? name : relative + "/" + name
        _ = try SafeFile.relativePath(child)
        let info = try inspect(root.appendingPathComponent(child))
        guard info.st_dev == device else {
          throw MisoError.invalid("Template traversal crosses a mount")
        }
        try body(child, info)
        if info.st_mode & S_IFMT == S_IFDIR { pending.append(child) }
      }
    }
  }
}

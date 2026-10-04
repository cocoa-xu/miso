import CryptoKit
import Darwin
import Foundation

enum Artifacts {
  static func clone(_ source: URL, to output: URL) throws {
    try SafeFile.requireNoSymlinks(source)
    try SafeFile.requireNoSymlinks(output.deletingLastPathComponent())
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    var info = stat()
    guard lstat(output.path, &info) != 0, errno == ENOENT else {
      throw MisoError.invalid("Clone destination already exists")
    }
    guard clonefile(source.path, output.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
      throw MisoError.system("Clone image on the same APFS volume", errno)
    }
  }

  static func record(
    _ url: URL, relativeTo root: URL, cancellation: CancellationToken? = nil
  ) throws -> ImageBundle.FileRecord {
    guard url.path.hasPrefix(root.path + "/") else {
      throw MisoError.invalid("Artifact is outside its operation")
    }
    let relative = try SafeFile.relativePath(String(url.path.dropFirst(root.path.count + 1)))
    let input = try SafeFile.openRegular(url)
    defer { try? input.close() }
    return ImageBundle.FileRecord(
      path: relative, bytes: try SafeFile.size(input),
      sha256: try SafeFile.sha256(input, cancellation: cancellation))
  }

  static func resolve(
    _ record: ImageBundle.FileRecord, under root: URL, cancellation: CancellationToken? = nil
  ) throws -> URL {
    let path = root.appendingPathComponent(try SafeFile.relativePath(record.path))
    try SafeFile.requireNoSymlinks(path)
    try SafeFile.validateSHA256(record.sha256)
    let input = try SafeFile.openRegular(path)
    defer { try? input.close() }
    guard try SafeFile.size(input) == record.bytes,
      try SafeFile.sha256(input, cancellation: cancellation) == record.sha256
    else {
      throw MisoError.invalid("Artifact changed: \(record.path)")
    }
    return path
  }

  static func copy(
    _ source: URL, to output: URL, maximumBytes: UInt64, cancellation: CancellationToken? = nil
  ) throws {
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let size = try SafeFile.size(input)
    guard size > 0, size <= maximumBytes else {
      throw MisoError.invalid("Invalid source file size")
    }
    let destination = try SafeFile.create(output)
    defer { try? destination.close() }
    var remaining = size
    while remaining > 0 {
      try cancellation?.check()
      try autoreleasepool {
        let data = try input.readExactly(Int(min(8 << 20, remaining)))
        try destination.write(contentsOf: data)
        remaining -= UInt64(data.count)
      }
    }
    guard try SafeFile.size(input) == size else {
      throw MisoError.invalid("Source size changed during copy")
    }
    try destination.synchronize()
  }

  static func moveDownload(
    _ source: URL, to output: URL, maximumBytes: UInt64, cancellation: CancellationToken? = nil
  ) throws {
    try cancellation?.check()
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let size = try SafeFile.size(input)
    guard size > 0, size <= maximumBytes else {
      throw MisoError.invalid("Invalid download size")
    }
    let parent = try SafeFile.openDirectory(output.deletingLastPathComponent())
    defer { close(parent) }
    guard
      renameatx_np(AT_FDCWD, source.path, parent, output.lastPathComponent, UInt32(RENAME_EXCL))
        == 0
    else {
      guard errno == EXDEV else {
        throw MisoError.system("Move download without replacing files", errno)
      }
      try copy(source, to: output, maximumBytes: maximumBytes, cancellation: cancellation)
      guard unlink(source.path) == 0 else {
        throw MisoError.system("Remove transferred download", errno)
      }
      return
    }
  }

  static func requireSpace(_ bytes: UInt64, at directory: URL) throws {
    var info = statfs()
    guard statfs(directory.path, &info) == 0 else {
      throw MisoError.system("Inspect available space", errno)
    }
    let (available, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(
      by: UInt64(info.f_bsize))
    guard !overflow, available >= bytes else {
      throw MisoError.invalid("Insufficient workspace capacity; requires \(bytes) available bytes")
    }
  }

  static func makeParents(for relative: String, under root: URL) throws -> URL {
    let parts = try SafeFile.relativePath(relative).split(separator: "/")
    var directory = root
    for part in parts.dropLast() {
      directory.appendPathComponent(String(part))
      var info = stat()
      if lstat(directory.path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR else {
          throw MisoError.invalid("Artifact parent is not a directory")
        }
      } else if errno == ENOENT {
        try SafeFile.makeDirectory(directory)
      } else {
        throw MisoError.system("Inspect artifact directory", errno)
      }
    }
    return root.appendingPathComponent(relative)
  }
}

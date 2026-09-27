import CryptoKit
import Darwin
import Foundation

public enum SafeFile {
  public static func relativePath(_ path: String) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
      !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".."
      })
    else {
      throw MisoError.invalid("Unsafe relative path: \(path)")
    }
    return path
  }

  public static func openRegular(_ url: URL) throws -> FileHandle {
    try openRegular(url, writable: false)
  }

  static func openRegular(_ url: URL, writable: Bool) throws -> FileHandle {
    let fd = open(url.path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MisoError.system("Open \(url.lastPathComponent)", errno) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw MisoError.system("Stat input", errno) }
    guard info.st_mode & S_IFMT == S_IFREG else {
      throw MisoError.invalid("Expected a regular file")
    }
    return handle
  }

  public static func size(_ handle: FileHandle) throws -> UInt64 {
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else {
      throw MisoError.system("Stat file", errno)
    }
    guard info.st_size >= 0 else { throw MisoError.invalid("Invalid file size") }
    return UInt64(info.st_size)
  }

  public static func read(_ url: URL, limit: Int) throws -> Data {
    guard limit > 0 else { throw MisoError.invalid("Invalid read limit") }
    let handle = try openRegular(url)
    defer { try? handle.close() }
    let expectedSize = try size(handle)
    guard expectedSize <= UInt64(limit) else {
      throw MisoError.invalid("Input exceeds \(limit) bytes")
    }
    let data = try handle.readExactly(Int(expectedSize))
    guard try (handle.read(upToCount: 1) ?? Data()).isEmpty, try size(handle) == expectedSize else {
      throw MisoError.invalid("Input size changed while reading")
    }
    return data
  }

  public static func create(_ url: URL) throws -> FileHandle {
    guard
      url.deletingLastPathComponent().resolvingSymlinksInPath().path
        == url.deletingLastPathComponent().standardizedFileURL.path
    else {
      throw MisoError.invalid("Output parent must not contain symbolic links")
    }
    let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw MisoError.system("Create \(url.lastPathComponent)", errno) }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  public static func writeNew(_ data: Data, to url: URL) throws {
    let handle = try create(url)
    defer { try? handle.close() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }

  static func replace(_ data: Data, at url: URL) throws {
    var existing = stat()
    if lstat(url.path, &existing) == 0 {
      guard existing.st_mode & S_IFMT == S_IFREG else {
        throw MisoError.invalid("Refusing to replace a non-regular file")
      }
    } else if errno != ENOENT {
      throw MisoError.system("Inspect atomic output", errno)
    }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString).tmp")
    try writeNew(data, to: temporary)
    defer { _ = unlink(temporary.path) }
    guard rename(temporary.path, url.path) == 0 else {
      throw MisoError.system("Publish atomic output", errno)
    }
    let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw MisoError.system("Open output directory", errno) }
    defer { close(parent) }
    guard fsync(parent) == 0 else { throw MisoError.system("Synchronize output directory", errno) }
  }

  public static func makeDirectory(_ url: URL) throws {
    guard
      url.deletingLastPathComponent().resolvingSymlinksInPath().path
        == url.deletingLastPathComponent().standardizedFileURL.path
    else {
      throw MisoError.invalid("Output parent must not contain symbolic links")
    }
    guard mkdir(url.path, 0o700) == 0 else {
      throw MisoError.system("Create output directory", errno)
    }
  }

  public static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

  public static func sha256(_ url: URL) throws -> String {
    let handle = try openRegular(url)
    defer { try? handle.close() }
    return try sha256(handle)
  }

  static func sha256(_ handle: FileHandle, cancellation: CancellationToken? = nil) throws -> String
  {
    let expectedSize = try size(handle)
    try handle.seek(toOffset: 0)
    var digest = SHA256()
    var consumed: UInt64 = 0
    while consumed < expectedSize {
      try autoreleasepool {
        try cancellation?.check()
        let chunk = try handle.readExactly(Int(min(8 << 20, expectedSize - consumed)))
        digest.update(data: chunk)
        consumed += UInt64(chunk.count)
      }
    }
    guard try (handle.read(upToCount: 1) ?? Data()).isEmpty, try size(handle) == expectedSize else {
      throw MisoError.invalid("Input size changed while hashing")
    }
    return hex(digest.finalize())
  }

  public static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public static func validateSHA256(_ value: String) throws {
    guard value.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else {
      throw MisoError.invalid("Expected a lowercase SHA-256 digest")
    }
  }
}

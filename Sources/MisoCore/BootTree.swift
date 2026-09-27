import CryptoKit
import Darwin
import Foundation

struct BootTree {
  struct Link: Codable, Sendable {
    let path: String
    let target: String
  }
  let root: URL

  init(journal: ExecutionJournal) throws {
    root = journal.output.appendingPathComponent("tree")
    try SafeFile.makeDirectory(root)
  }

  func write(_ relative: String, _ data: Data) throws {
    try SafeFile.writeNew(data, to: Artifacts.makeParents(for: relative, under: root))
  }

  func plist(_ relative: String, _ value: [String: Any]) throws {
    try write(
      relative, PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    )
  }

  func clone(_ source: URL, _ relative: String) throws {
    try Artifacts.clone(source, to: Artifacts.makeParents(for: relative, under: root))
  }

  func directory(_ relative: String) throws {
    let path = try Artifacts.makeParents(for: relative + "/.parent-check", under: root)
      .deletingLastPathComponent()
    guard try FileMetadata.inspect(path).st_mode & S_IFMT == S_IFDIR else {
      throw MisoError.invalid("Invalid boot directory")
    }
  }

  func inventory(cancellation: CancellationToken) throws -> (
    [ImageBundle.FileRecord], [String], [Link]
  ) {
    var files: [ImageBundle.FileRecord] = []
    var directories: [String] = []
    var links: [Link] = []
    try FileMetadata.walk(root) { relative, info in
      try cancellation.check()
      let path = root.appendingPathComponent(relative)
      switch info.st_mode & S_IFMT {
      case S_IFREG: files.append(try Artifacts.record(path, relativeTo: root))
      case S_IFDIR: directories.append(relative)
      case S_IFLNK:
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
        _ = try SafeFile.relativePath(target)
        links.append(Link(path: relative, target: target))
      default: throw MisoError.invalid("Unexpected boot-tree entry")
      }
    }
    return (
      files.sorted { $0.path < $1.path }, directories.sorted(), links.sorted { $0.path < $1.path }
    )
  }

  static func hash384(_ file: URL, cancellation: CancellationToken? = nil) throws -> Data {
    let handle = try SafeFile.openRegular(file)
    defer { try? handle.close() }
    let expectedSize = try SafeFile.size(handle)
    var hash = SHA384()
    var consumed: UInt64 = 0
    while consumed < expectedSize {
      try autoreleasepool {
        try cancellation?.check()
        let data = try handle.readExactly(Int(min(8 << 20, expectedSize - consumed)))
        hash.update(data: data)
        consumed += UInt64(data.count)
      }
    }
    guard
      try (handle.read(upToCount: 1) ?? Data()).isEmpty,
      try SafeFile.size(handle) == expectedSize
    else {
      throw MisoError.invalid("Input size changed while hashing")
    }
    return Data(hash.finalize())
  }

  static func recoveryIdentifier(_ group: UUID) -> UUID {
    var namespace = group.uuid
    let data = withUnsafeBytes(of: &namespace) { Data($0) } + Data("system-recovery".utf8)
    var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

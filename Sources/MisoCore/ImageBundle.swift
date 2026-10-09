import Darwin
import Foundation

public enum ImageBundle {
  struct FileState: Equatable {
    let device: dev_t
    let inode: ino_t
    let bytes: UInt64
    let modified: [Int]
    let changed: [Int]
  }

  static func snapshot(_ directory: URL, files: Set<String> = requiredFiles) throws -> [String:
    FileState]
  {
    try Dictionary(
      uniqueKeysWithValues: files.map { name in
        let url = directory.appendingPathComponent(name)
        try SafeFile.requireNoSymlinks(url)
        let info = try FileMetadata.inspect(url)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
          throw MisoError.invalid("Expected nonempty bundle file")
        }
        return (
          name,
          FileState(
            device: info.st_dev, inode: info.st_ino, bytes: UInt64(info.st_size),
            modified: [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec],
            changed: [info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec])
        )
      })
  }

  public static let requiredFiles: Set<String> = [
    "disk.img", "aux.bin", "hardware-model.bin", "machine-identifier.bin",
  ]

  public struct FileRecord: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let sha256: String
  }

  public struct Manifest: Decodable {
    public let schemaVersion: Int
    public let files: [FileRecord]
    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case files
    }

    public func validate() throws {
      guard schemaVersion == 1, files.count == requiredFiles.count,
        Set(files.map(\.path)) == requiredFiles
      else { throw MisoError.invalid("Invalid bundle manifest file set or schema") }
      for file in files {
        try SafeFile.validateSHA256(file.sha256)
        guard file.bytes > 0 else { throw MisoError.invalid("Empty bundle file") }
      }
    }
  }

  public struct Verification: Encodable, Sendable {
    public let host: HostInfo
    public let files: [FileRecord]
    public let manifestMatches = true
    public let vmStarted = false
    public let bootabilityProven = false
  }

  public static func verify(_ directory: URL, cancellation: CancellationToken? = nil) throws
    -> Verification
  {
    let manifest = try JSON.read(
      Manifest.self, from: directory.appendingPathComponent("manifest.json"), limit: 1 << 20)
    try manifest.validate()
    for record in manifest.files {
      let url = directory.appendingPathComponent(record.path)
      let file = try SafeFile.openRegular(url)
      defer { try? file.close() }
      guard try SafeFile.size(file) == record.bytes,
        try SafeFile.sha256(file, cancellation: cancellation) == record.sha256
      else {
        throw MisoError.invalid("Bundle file differs from manifest: \(record.path)")
      }
    }
    return Verification(host: try HostInfo.current(), files: manifest.files)
  }
}

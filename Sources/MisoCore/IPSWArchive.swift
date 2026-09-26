import CryptoKit
import Darwin
import Foundation
import ZIPFoundation

public final class IPSWArchive {
  private let archive: Archive
  private let entries: [String: Entry]
  private let modes: [String: UInt32]

  public init(_ url: URL) throws {
    let handle = try SafeFile.openRegular(url)
    defer { try? handle.close() }
    let directory = try ZIPDirectory(handle)
    archive = try Archive(url: url, accessMode: .read)
    var indexed: [String: Entry] = [:]
    for entry in archive {
      guard indexed.count < 100_000, indexed[entry.path] == nil else {
        throw MisoError.invalid("Duplicate IPSW member")
      }
      indexed[entry.path] = entry
    }
    guard Set(indexed.keys) == Set(directory.fileModes.keys) else {
      throw MisoError.invalid("Unreadable ZIP directory entries")
    }
    entries = indexed
    modes = directory.fileModes
  }

  private func regularEntry(_ path: String) throws -> Entry {
    _ = try SafeFile.relativePath(path)
    guard let entry = entries[path], entry.type == .file, entry.uncompressedSize > 0,
      let mode = modes[path], mode & UInt32(S_IFMT) == 0 || mode & UInt32(S_IFMT) == S_IFREG
    else {
      throw MisoError.invalid("Missing or non-regular IPSW member: \(path)")
    }
    return entry
  }

  public func requireComponent(_ path: String) throws { _ = try regularEntry(path) }

  public func read(_ path: String, limit: Int = 64 << 20) throws -> Data {
    guard limit > 0 else { throw MisoError.invalid("Invalid member size limit") }
    let entry = try regularEntry(path)
    guard entry.uncompressedSize <= UInt64(limit) else {
      throw MisoError.invalid("IPSW member exceeds size limit")
    }
    var data = Data()
    let checksum = try archive.extract(entry, bufferSize: 1 << 20) { chunk in
      guard chunk.count <= limit - data.count else {
        throw MisoError.invalid("IPSW member expanded beyond size limit")
      }
      data.append(chunk)
    }
    guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else {
      throw MisoError.invalid("IPSW member checksum or size mismatch")
    }
    return data
  }

  public struct Extraction: Encodable, Sendable {
    public let member: String
    public let bytes: UInt64
    public let sha256: String
    public let payloadAuthenticated = false
  }

  public func extract(_ member: String, to output: URL, expectedSHA256: String) throws -> Extraction
  {
    try SafeFile.validateSHA256(expectedSHA256)
    let entry = try regularEntry(member)
    let handle = try SafeFile.create(output)
    defer { try? handle.close() }
    var written: UInt64 = 0
    var hash = SHA256()
    let checksum = try archive.extract(entry, bufferSize: 8 << 20) { chunk in
      try autoreleasepool {
        guard UInt64(chunk.count) <= entry.uncompressedSize - written else {
          throw MisoError.invalid("IPSW member exceeds declared size")
        }
        try handle.write(contentsOf: chunk)
        hash.update(data: chunk)
        written += UInt64(chunk.count)
      }
    }
    let digest = SafeFile.hex(hash.finalize())
    guard checksum == entry.checksum, written == entry.uncompressedSize, digest == expectedSHA256
    else {
      throw MisoError.invalid("Extracted member checksum mismatch; incomplete output retained")
    }
    try handle.synchronize()
    return Extraction(member: member, bytes: written, sha256: digest)
  }
}

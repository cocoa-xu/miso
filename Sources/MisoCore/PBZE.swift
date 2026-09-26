import Compression
import CryptoKit
import Foundation

public enum PBZE {
  public struct Receipt: Encodable, Sendable {
    public let bytes: UInt64
    public let sha256: String
  }

  public static func decode(source: URL, output: URL, maximumOutputBytes: UInt64 = 512 << 20) throws
    -> Receipt
  {
    guard maximumOutputBytes > 0, maximumOutputBytes <= 4 << 30 else {
      throw MisoError.invalid("Invalid PBZE output limit")
    }
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let size = try SafeFile.size(input)
    guard size >= 12, size <= maximumOutputBytes + (1 << 20) else {
      throw MisoError.invalid("Invalid PBZE input size")
    }
    let header = try input.readExactly(12)
    let blockSize = try header.integer(at: 4, as: UInt64.self, bigEndian: true)
    guard header.prefix(4) == Data("pbze".utf8), blockSize > 0, blockSize <= 64 << 20 else {
      throw MisoError.invalid("Invalid PBZE header")
    }
    let destination = try SafeFile.create(output)
    defer { try? destination.close() }
    var position: UInt64 = 12
    var written: UInt64 = 0
    var digest = SHA256()
    while position < size {
      try autoreleasepool {
        guard size - position >= 16 else { throw MisoError.invalid("Truncated PBZE chunk header") }
        let chunkHeader = try input.readExactly(16)
        position += 16
        let expanded = try chunkHeader.integer(at: 0, as: UInt64.self, bigEndian: true)
        let compressed = try chunkHeader.integer(at: 8, as: UInt64.self, bigEndian: true)
        guard expanded > 0, expanded <= blockSize, compressed > 0, compressed <= expanded,
          compressed <= size - position, expanded <= maximumOutputBytes - written
        else {
          throw MisoError.invalid("Invalid PBZE chunk bounds")
        }
        let data = try input.readExactly(Int(compressed))
        position += compressed
        let decoded: Data
        if compressed == expanded {
          decoded = data
        } else {
          var buffer = Data(count: Int(expanded))
          let count = buffer.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
              compression_decode_buffer(
                target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE
              )
            }
          }
          guard count == expanded else { throw MisoError.invalid("PBZE decoded size mismatch") }
          decoded = buffer
        }
        try destination.write(contentsOf: decoded)
        digest.update(data: decoded)
        written += expanded
      }
    }
    guard written > 0, try SafeFile.size(input) == size else {
      throw MisoError.invalid("Empty or changed PBZE source")
    }
    try destination.synchronize()
    return Receipt(bytes: written, sha256: SafeFile.hex(digest.finalize()))
  }
}

import CryptoKit
import Foundation

extension Image4 {
  public static func unwrap(
    source: URL, output: URL, maximumBytes: UInt64 = 4 << 30,
    cancellation: CancellationToken? = nil
  ) throws -> ImageBundle.FileRecord {
    guard maximumBytes > 0, maximumBytes <= 32 << 30 else {
      throw MisoError.invalid("Invalid Image4 size limit")
    }
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let size = try SafeFile.size(input)
    guard size <= maximumBytes + (1 << 20) else {
      throw MisoError.invalid("Image4 exceeds size limit")
    }
    let reader = DERFileReader(input: input, size: size)
    let outer = try reader.header()
    guard outer.tag == 0x30, outer.end == size else {
      throw MisoError.invalid("Invalid Image4 outer sequence")
    }
    guard try reader.string() == "IM4P", try reader.string().utf8.count == 4 else {
      throw MisoError.invalid("Invalid Image4 payload header")
    }
    _ = try reader.string()
    let payload = try reader.header()
    guard payload.tag == 4, payload.size > 0, payload.size <= maximumBytes else {
      throw MisoError.invalid("Invalid Image4 payload bounds")
    }
    let destination = try SafeFile.create(output)
    defer { try? destination.close() }
    var remaining = payload.size
    var digest = SHA256()
    while remaining > 0 {
      try cancellation?.check()
      try autoreleasepool {
        let data = try input.readExactly(Int(min(8 << 20, remaining)))
        try destination.write(contentsOf: data)
        digest.update(data: data)
        remaining -= UInt64(data.count)
      }
    }
    let trailing = size - payload.end
    guard trailing <= 64 << 10 else { throw MisoError.invalid("Image4 trailer exceeds limit") }
    _ = try DER.nodes(input.readExactly(Int(trailing)))
    guard try SafeFile.size(input) == size else { throw MisoError.invalid("Image4 source changed") }
    try destination.synchronize()
    return ImageBundle.FileRecord(
      path: output.lastPathComponent, bytes: payload.size, sha256: SafeFile.hex(digest.finalize()))
  }
}

private struct DERFileReader {
  let input: FileHandle
  let size: UInt64

  func header() throws -> (tag: UInt8, size: UInt64, end: UInt64) {
    let bytes = try input.readExactly(2)
    guard bytes[0] & 31 != 31 else { throw MisoError.invalid("Unexpected extended payload tag") }
    var length = UInt64(bytes[1])
    if length & 128 != 0 {
      let count = Int(length & 127)
      guard count > 0, count <= 5 else { throw MisoError.invalid("Invalid payload length") }
      let encoded = try input.readExactly(count)
      guard encoded[0] != 0 else { throw MisoError.invalid("Noncanonical payload length") }
      length = encoded.reduce(0) { ($0 << 8) | UInt64($1) }
      guard length >= 128 else { throw MisoError.invalid("Noncanonical payload length") }
    }
    let offset = try input.offset()
    guard offset <= size, length <= size - offset else {
      throw MisoError.invalid("Truncated payload")
    }
    return (bytes[0], length, offset + length)
  }

  func string() throws -> String {
    let field = try header()
    guard field.tag == 0x16, field.size <= 4096,
      let result = String(data: try input.readExactly(Int(field.size)), encoding: .ascii)
    else {
      throw MisoError.invalid("Invalid Image4 string field")
    }
    return result
  }
}

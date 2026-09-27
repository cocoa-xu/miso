import CMiso
import CryptoKit
import Foundation

struct GitPack {
  struct Object {
    let type: String
    let data: Data
    let offset: Int
    let crc32: UInt32
    let deltaDepth: Int

    var id: Data {
      Data(Insecure.SHA1.hash(data: Data("\(type) \(data.count)\0".utf8) + data))
    }
  }

  private struct Entry {
    let type: UInt8
    let data: Data
    let offset: Int
    let crc32: UInt32
    let baseOffset: Int?
    let baseID: Data?
  }

  static let objectLimit = 64 << 20
  let bytes: Data
  let objects: [Data: Object]

  init(_ bytes: Data, cancellation: CancellationToken? = nil) throws {
    let bytes = Data(bytes)
    guard bytes.count >= 32, bytes.count <= 128 << 20,
      bytes.prefix(4) == Data("PACK".utf8),
      try bytes.integer(at: 4, as: UInt32.self, bigEndian: true) == 2,
      Data(Insecure.SHA1.hash(data: bytes.dropLast(20))) == bytes.suffix(20)
    else { throw MisoError.invalid("Invalid Git pack header or checksum") }
    let count = Int(try bytes.integer(at: 8, as: UInt32.self, bigEndian: true))
    guard (1...50_000).contains(count) else { throw MisoError.invalid("Invalid Git object count") }
    var cursor = Cursor(data: Data(bytes.dropLast(20)), offset: 12)
    var entries: [Entry] = []
    entries.reserveCapacity(count)
    var total = 0
    for _ in 0..<count {
      try cancellation?.check()
      let offset = cursor.offset
      var byte = try cursor.byte()
      let type = (byte >> 4) & 7
      var size = Int(byte & 15)
      var shift = 4
      while byte & 128 != 0 {
        guard shift <= 25 else { throw MisoError.invalid("Oversized Git object") }
        byte = try cursor.byte()
        size |= Int(byte & 127) << shift
        shift += 7
      }
      guard size <= Self.objectLimit else { throw MisoError.invalid("Oversized Git object") }
      var baseOffset: Int?
      var baseID: Data?
      if type == 6 {
        byte = try cursor.byte()
        var distance = Int(byte & 127)
        while byte & 128 != 0 {
          guard distance < 128 << 20 else { throw MisoError.invalid("Invalid Git delta offset") }
          byte = try cursor.byte()
          distance = ((distance + 1) << 7) | Int(byte & 127)
        }
        guard distance > 0, distance <= offset - 12 else {
          throw MisoError.invalid("Invalid Git delta offset")
        }
        baseOffset = offset - distance
      } else if type == 7 {
        baseID = try cursor.take(20)
      } else if !(1...4).contains(type) {
        throw MisoError.invalid("Unknown Git object type")
      }
      total += size
      guard total <= 512 << 20 else { throw MisoError.invalid("Excessive Git object data") }
      let decoded = try Self.inflate(cursor.data, offset: cursor.offset, size: size)
      cursor.offset += decoded.consumed
      entries.append(
        Entry(
          type: type, data: decoded.data, offset: offset,
          crc32: Data(cursor.data[offset..<cursor.offset]).crc32,
          baseOffset: baseOffset, baseID: baseID))
    }
    guard cursor.offset == cursor.data.count else {
      throw MisoError.invalid("Trailing Git pack data")
    }
    var offsets: [Int: Object] = [:]
    var objects: [Data: Object] = [:]
    var pending = entries
    for _ in 0...64 {
      var remaining: [Entry] = []
      for entry in pending {
        try cancellation?.check()
        let type: String
        let data: Data
        let depth: Int
        if entry.type <= 4 {
          type = ["", "commit", "tree", "blob", "tag"][Int(entry.type)]
          data = entry.data
          depth = 0
        } else {
          let base =
            entry.baseOffset.flatMap { offsets[$0] } ?? entry.baseID.flatMap { objects[$0] }
          guard let base else {
            remaining.append(entry)
            continue
          }
          depth = base.deltaDepth + 1
          guard depth <= 64 else { throw MisoError.invalid("Excessive Git delta depth") }
          type = base.type
          data = try Self.applyDelta(entry.data, to: base.data)
          total += data.count
          guard total <= 512 << 20 else { throw MisoError.invalid("Excessive Git delta data") }
        }
        let object = Object(
          type: type, data: data, offset: entry.offset, crc32: entry.crc32, deltaDepth: depth)
        guard objects.updateValue(object, forKey: object.id) == nil else {
          throw MisoError.invalid("Duplicate Git object")
        }
        offsets[entry.offset] = object
      }
      if remaining.isEmpty {
        pending = []
        break
      }
      guard remaining.count < pending.count else { throw MisoError.invalid("Unresolved Git delta") }
      pending = remaining
    }
    guard pending.isEmpty else { throw MisoError.invalid("Excessive Git delta depth") }
    self.bytes = bytes
    self.objects = objects
  }

  static func inflate(_ data: Data, offset: Int, size: Int) throws -> (data: Data, consumed: Int) {
    guard offset >= 0, offset < data.count, (0...objectLimit).contains(size) else {
      throw MisoError.invalid("Invalid Git compressed object")
    }
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw MisoError.invalid("Initialize Git decompressor")
    }
    defer { inflateEnd(&stream) }
    var output = Data(count: size + 1)
    let status = data.withUnsafeBytes { input in
      output.withUnsafeMutableBytes { destination in
        stream.next_in = UnsafeMutablePointer(
          mutating: input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset))
        stream.avail_in = UInt32(data.count - offset)
        stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
        stream.avail_out = UInt32(size + 1)
        return CMiso.inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, stream.total_out == size, stream.total_in > 0 else {
      throw MisoError.invalid("Invalid Git compressed object size or stream")
    }
    output.removeLast()
    return (output, Int(stream.total_in))
  }

  static func applyDelta(_ delta: Data, to base: Data) throws -> Data {
    var cursor = Cursor(data: delta)
    guard try cursor.variable() == base.count else {
      throw MisoError.invalid("Git delta base size mismatch")
    }
    let size = try cursor.variable()
    guard size <= objectLimit else { throw MisoError.invalid("Oversized Git delta result") }
    var output = Data()
    output.reserveCapacity(size)
    while cursor.offset < delta.count {
      let command = try cursor.byte()
      if command & 128 != 0 {
        var offset = 0
        var count = 0
        for bit in 0..<4 where command & (1 << bit) != 0 {
          offset |= Int(try cursor.byte()) << (bit * 8)
        }
        for bit in 0..<3 where command & (16 << bit) != 0 {
          count |= Int(try cursor.byte()) << (bit * 8)
        }
        if count == 0 { count = 0x10000 }
        guard offset <= base.count, count <= base.count - offset, count <= size - output.count
        else {
          throw MisoError.invalid("Git delta copy exceeds bounds")
        }
        output.append(base[(base.startIndex + offset)..<(base.startIndex + offset + count)])
      } else {
        guard command > 0, Int(command) <= size - output.count else {
          throw MisoError.invalid("Invalid Git delta insertion")
        }
        output.append(try cursor.take(Int(command)))
      }
    }
    guard output.count == size else { throw MisoError.invalid("Git delta result size mismatch") }
    return output
  }

  var index: Data {
    let sorted = objects.sorted { $0.key.lexicographicallyPrecedes($1.key) }
    var output = Data([255, 116, 79, 99])
    output.appendGitInteger(2)
    var count = 0
    for byte in 0..<256 {
      while count < sorted.count, Int(sorted[count].key.first!) <= byte { count += 1 }
      output.appendGitInteger(UInt32(count))
    }
    for (id, _) in sorted { output.append(id) }
    for (_, object) in sorted { output.appendGitInteger(object.crc32) }
    for (_, object) in sorted { output.appendGitInteger(UInt32(object.offset)) }
    output.append(bytes.suffix(20))
    output.append(contentsOf: Insecure.SHA1.hash(data: output))
    return output
  }

  struct Cursor {
    let data: Data
    var offset = 0

    mutating func take(_ count: Int) throws -> Data {
      guard count >= 0, offset <= data.count, count <= data.count - offset else {
        throw MisoError.invalid("Truncated Git data")
      }
      defer { offset += count }
      return Data(data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
    }

    mutating func byte() throws -> UInt8 {
      guard offset < data.count else { throw MisoError.invalid("Truncated Git data") }
      defer { offset += 1 }
      return data[data.startIndex + offset]
    }

    mutating func variable() throws -> Int {
      var value = 0
      for shift in stride(from: 0, through: 28, by: 7) {
        let byte = try byte()
        value |= Int(byte & 127) << shift
        guard value <= GitPack.objectLimit else {
          throw MisoError.invalid("Oversized Git delta integer")
        }
        if byte & 128 == 0 { return value }
      }
      throw MisoError.invalid("Invalid Git delta integer")
    }
  }
}

extension Data {
  mutating func appendGitInteger(_ value: UInt32) {
    for shift in stride(from: 24, through: 0, by: -8) {
      append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }
}

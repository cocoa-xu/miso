import CMiso
import Foundation

extension Data {
  func integer<T: FixedWidthInteger>(
    at offset: Int, as type: T.Type = T.self, bigEndian: Bool = false
  ) throws -> T {
    let size = MemoryLayout<T>.size
    guard offset >= 0, offset <= count, size <= count - offset else {
      throw MisoError.invalid("Truncated binary integer")
    }
    var value: T = 0
    for index in 0..<size {
      let byte = self[startIndex + offset + index]
      value |= T(truncatingIfNeeded: byte) << ((bigEndian ? size - 1 - index : index) * 8)
    }
    return value
  }

  mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
    precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count)
    for index in 0..<MemoryLayout<T>.size {
      self[startIndex + offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
    }
  }

  var crc32: UInt32 {
    withUnsafeBytes {
      UInt32(CMiso.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(count)))
    }
  }
}

extension FileHandle {
  func readExactly(_ count: Int, at offset: UInt64? = nil) throws -> Data {
    guard count >= 0 else { throw MisoError.invalid("Negative read size") }
    if let offset { try seek(toOffset: offset) }
    var result = Data()
    while result.count < count {
      guard let chunk = try read(upToCount: count - result.count), !chunk.isEmpty else {
        throw MisoError.invalid("Unexpected end of file")
      }
      result.append(chunk)
    }
    return result
  }
}

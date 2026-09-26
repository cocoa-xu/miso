import Darwin
import Foundation

struct ZIPDirectory {
  let fileModes: [String: UInt32]

  init(_ handle: FileHandle) throws {
    let size = try SafeFile.size(handle)
    guard size >= 22 else { throw MisoError.invalid("Truncated ZIP archive") }
    let tailSize = min(size, 65_557)
    let tail = try handle.readExactly(Int(tailSize), at: size - tailSize)
    guard
      let end = try stride(from: tail.count - 22, through: 0, by: -1).first(where: {
        try tail.integer(at: $0, as: UInt32.self) == 0x0605_4b50
          && $0 + 22 + Int(tail.integer(at: $0 + 20, as: UInt16.self)) == tail.count
      })
    else { throw MisoError.invalid("Missing ZIP end record") }
    guard try tail.integer(at: end + 4, as: UInt16.self) == 0,
      try tail.integer(at: end + 6, as: UInt16.self) == 0,
      try tail.integer(at: end + 8, as: UInt16.self) == tail.integer(at: end + 10, as: UInt16.self)
    else {
      throw MisoError.unsupported("multi-volume ZIP archive")
    }
    var count = UInt64(try tail.integer(at: end + 10, as: UInt16.self))
    var bytes = UInt64(try tail.integer(at: end + 12, as: UInt32.self))
    var offset = UInt64(try tail.integer(at: end + 16, as: UInt32.self))
    var directoryLimit = size - tailSize + UInt64(end)
    if count == UInt16.max || bytes == UInt32.max || offset == UInt32.max {
      guard directoryLimit >= 20 else { throw MisoError.invalid("Missing ZIP64 locator") }
      let locator = try handle.readExactly(20, at: directoryLimit - 20)
      guard try locator.integer(at: 0, as: UInt32.self) == 0x0706_4b50,
        try locator.integer(at: 4, as: UInt32.self) == 0,
        try locator.integer(at: 16, as: UInt32.self) == 1
      else { throw MisoError.invalid("Invalid ZIP64 locator") }
      let recordOffset = try locator.integer(at: 8, as: UInt64.self)
      guard directoryLimit >= 76, recordOffset <= directoryLimit - 76 else {
        throw MisoError.invalid("Invalid ZIP64 record offset")
      }
      let record = try handle.readExactly(56, at: recordOffset)
      let recordSize = try record.integer(at: 4, as: UInt64.self)
      guard try record.integer(at: 0, as: UInt32.self) == 0x0606_4b50,
        recordSize >= 44, recordSize <= directoryLimit - 20 - recordOffset - 12,
        try record.integer(at: 16, as: UInt32.self) == 0,
        try record.integer(at: 20, as: UInt32.self) == 0,
        try record.integer(at: 24, as: UInt64.self) == record.integer(at: 32, as: UInt64.self)
      else {
        throw MisoError.invalid("Invalid ZIP64 end record")
      }
      count = try record.integer(at: 32)
      bytes = try record.integer(at: 40)
      offset = try record.integer(at: 48)
      directoryLimit = recordOffset
    }
    guard count > 0, count <= 100_000, bytes <= 64 << 20, offset <= directoryLimit,
      bytes <= directoryLimit - offset
    else {
      throw MisoError.invalid("Invalid ZIP directory bounds")
    }
    let directory = try handle.readExactly(Int(bytes), at: offset)
    var cursor = 0
    var modes: [String: UInt32] = [:]
    for _ in 0..<count {
      guard cursor <= directory.count - 46,
        try directory.integer(at: cursor, as: UInt32.self) == 0x0201_4b50
      else {
        throw MisoError.invalid("Truncated ZIP directory entry")
      }
      let flags = try directory.integer(at: cursor + 8, as: UInt16.self)
      let nameSize = Int(try directory.integer(at: cursor + 28, as: UInt16.self))
      let extraSize = Int(try directory.integer(at: cursor + 30, as: UInt16.self))
      let commentSize = Int(try directory.integer(at: cursor + 32, as: UInt16.self))
      let length = 46 + nameSize + extraSize + commentSize
      guard length <= directory.count - cursor, flags & 0x41 == 0,
        try directory.integer(at: cursor + 34, as: UInt16.self) == 0
      else {
        throw MisoError.invalid("Encrypted, split or truncated ZIP entry")
      }
      let nameData = directory.subdata(in: cursor + 46..<cursor + 46 + nameSize)
      guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty, !name.contains("\0"),
        modes[name] == nil
      else {
        throw MisoError.invalid("Ambiguous or invalid ZIP entry name")
      }
      modes[name] = try directory.integer(at: cursor + 38, as: UInt32.self) >> 16
      cursor += length
    }
    guard cursor == directory.count else {
      throw MisoError.invalid("Unexpected ZIP directory trailing data")
    }
    fileModes = modes
  }
}

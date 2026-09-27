import Foundation

enum XART {
  struct Patch: Codable, Sendable {
    let offset: UInt64
    let beforeSHA256: String
    let afterSHA256: String
  }

  static func checksum(_ block: Data) throws -> Data {
    guard block.count == 4096 else { throw MisoError.invalid("Invalid APFS object size") }
    let modulus = UInt64(UInt32.max)
    var first: UInt64 = 0
    var second: UInt64 = 0
    for offset in stride(from: 8, to: 4096, by: 4) {
      first = (first + UInt64(try block.integer(at: offset, as: UInt32.self))) % modulus
      second = (second + first) % modulus
    }
    let low = modulus - (first + second) % modulus
    let high = modulus - (first + low) % modulus
    var result = Data(count: 8)
    result.put(UInt32(low), at: 0)
    result.put(UInt32(high), at: 4)
    return result
  }

  static func changed(_ block: Data, volume: UUID) throws -> Data? {
    guard block.count == 4096 else { throw MisoError.invalid("Invalid APFS object size") }
    guard block[32..<36] == Data("APSB".utf8), block[240..<256] == volume.bytes else { return nil }
    guard try checksum(block) == block.prefix(8), try block.integer(at: 964, as: UInt16.self) == 0,
      try block.integer(at: 216, as: UInt64.self) == 0
    else { throw MisoError.invalid("xART placeholder is not empty or has an invalid checksum") }
    var result = block
    result.put(UInt16(0x100), at: 964)
    result.replaceSubrange(0..<8, with: try checksum(result))
    return result
  }

  static func initialize(
    _ session: DiskImageSession, volume: UUID, partition: DiskLayout.Partition,
    journal: ExecutionJournal
  ) throws -> [Patch] {
    guard partition.type == DiskLayout.iscType, partition.offset == 1 << 20,
      partition.size == 512 << 20
    else {
      throw MisoError.unsupported("xART partition geometry")
    }
    return try session.withDetachedFile { file in
      guard try SafeFile.size(file) >= partition.offset + partition.size else {
        throw MisoError.invalid("Truncated iSC partition")
      }
      let header = try file.readExactly(4096, at: partition.offset)
      guard header[32..<36] == Data("NXSB".utf8),
        try header.integer(at: 36, as: UInt32.self) == 4096,
        try header.integer(at: 40, as: UInt64.self) == partition.size / 4096
      else { throw MisoError.invalid("iSC container geometry mismatch") }
      var patches: [(UInt64, Data, Data)] = []
      try file.seek(toOffset: partition.offset)
      for offset in stride(from: partition.offset, to: partition.offset + partition.size, by: 4096)
      {
        try journal.cancellation.check()
        try autoreleasepool {
          let before = try file.readExactly(4096)
          if let after = try changed(before, volume: volume) {
            guard patches.count < 64 else { throw MisoError.invalid("Too many xART checkpoints") }
            patches.append((offset, before, after))
          }
        }
      }
      guard !patches.isEmpty else { throw MisoError.invalid("No xART placeholder checkpoints") }
      try Artifacts.clone(
        session.image, to: journal.output.appendingPathComponent("before-xart.img"))
      for (offset, before, after) in patches {
        guard try file.readExactly(4096, at: offset) == before else {
          throw MisoError.invalid("xART checkpoint changed before write")
        }
        try file.seek(toOffset: offset)
        try file.write(contentsOf: after)
      }
      return patches.map {
        .init(offset: $0.0, beforeSHA256: SafeFile.sha256($0.1), afterSHA256: SafeFile.sha256($0.2))
      }
    }
  }
}

import Foundation

struct MachOImage {
  struct Segment {
    let address: UInt64
    let offset: UInt64
    let size: UInt64
  }

  let data: Data
  let type: UInt32
  let members: [String: UInt64]
  let segments: [Segment]
  let symbols: [String: UInt64]
  let ambiguousSymbols: Set<String>

  init(_ data: Data, offset: Int = 0) throws {
    self.data = data
    guard offset >= 0, offset <= data.count - 32,
      try data.integer(at: offset, as: UInt32.self) == 0xFEED_FACF,
      try data.integer(at: offset + 4, as: UInt32.self) == 0x0100_000C
    else { throw MisoError.invalid("Expected a bounded arm64 Mach-O image") }
    type = try data.integer(at: offset + 12, as: UInt32.self)
    let count = Int(try data.integer(at: offset + 16, as: UInt32.self))
    let bytes = Int(try data.integer(at: offset + 20, as: UInt32.self))
    guard count <= 100_000, bytes <= data.count - offset - 32 else {
      throw MisoError.invalid("Invalid Mach-O load command region")
    }
    var cursor = offset + 32
    let end = cursor + bytes
    var members: [String: UInt64] = [:]
    var segments: [Segment] = []
    var table: (Int, Int, Int, Int)?
    for _ in 0..<count {
      guard cursor <= end - 8 else { throw MisoError.invalid("Truncated Mach-O load command") }
      let command = try data.integer(at: cursor, as: UInt32.self)
      let size = Int(try data.integer(at: cursor + 4, as: UInt32.self))
      guard size >= 8, size % 8 == 0, size <= end - cursor else {
        throw MisoError.invalid("Invalid Mach-O load command size")
      }
      switch command {
      case 0x8000_0035:
        guard size >= 32, type == 12 else { throw MisoError.invalid("Invalid fileset entry") }
        let memberOffset = try data.integer(at: cursor + 16, as: UInt64.self)
        let nameOffset = Int(try data.integer(at: cursor + 24, as: UInt32.self))
        guard nameOffset >= 32, nameOffset < size, memberOffset <= data.count - 32 else {
          throw MisoError.invalid("Fileset member exceeds collection bounds")
        }
        let name = try Self.string(data, at: cursor + nameOffset, limit: cursor + size)
        guard !name.isEmpty, members[name] == nil else {
          throw MisoError.invalid("Duplicate fileset member")
        }
        members[name] = memberOffset
      case 0x19:
        guard size >= 72 else { throw MisoError.invalid("Truncated Mach-O segment") }
        let address = try data.integer(at: cursor + 24, as: UInt64.self)
        let fileOffset = try data.integer(at: cursor + 40, as: UInt64.self)
        let fileSize = try data.integer(at: cursor + 48, as: UInt64.self)
        guard fileOffset <= data.count, fileSize <= UInt64(data.count) - fileOffset else {
          throw MisoError.invalid("Mach-O segment exceeds file bounds")
        }
        segments.append(Segment(address: address, offset: fileOffset, size: fileSize))
      case 0x2:
        guard size == 24, table == nil else {
          throw MisoError.invalid("Invalid Mach-O symbol table")
        }
        table = (
          Int(try data.integer(at: cursor + 8, as: UInt32.self)),
          Int(try data.integer(at: cursor + 12, as: UInt32.self)),
          Int(try data.integer(at: cursor + 16, as: UInt32.self)),
          Int(try data.integer(at: cursor + 20, as: UInt32.self))
        )
      default: break
      }
      cursor += size
    }
    guard cursor == end else { throw MisoError.invalid("Mach-O command count mismatch") }
    var symbols: [String: UInt64] = [:]
    var ambiguous = Set<String>()
    if let (offset, count, strings, size) = table {
      guard offset <= data.count, count <= (data.count - offset) / 16, count <= 2_000_000,
        strings <= data.count, size <= data.count - strings
      else { throw MisoError.invalid("Mach-O symbol table exceeds file bounds") }
      for index in 0..<count {
        let entry = offset + index * 16
        let kind = data[entry + 4]
        if kind & 0xE0 != 0 || kind & 0x0E != 0x0E { continue }
        let start = Int(try data.integer(at: entry, as: UInt32.self))
        guard start < size else { throw MisoError.invalid("Invalid Mach-O symbol name offset") }
        let name = try Self.string(data, at: strings + start, limit: strings + size)
        if !name.isEmpty {
          let address = try data.integer(at: entry + 8, as: UInt64.self)
          if let previous = symbols[name], previous != address {
            ambiguous.insert(name)
          }
          symbols[name] = address
        }
      }
    }
    self.members = members
    self.segments = segments
    self.symbols = symbols
    ambiguousSymbols = ambiguous
  }

  func member(_ name: String) throws -> Self {
    guard let offset = members[name] else {
      throw MisoError.invalid("Required fileset member is absent")
    }
    return try Self(data, offset: Int(offset))
  }

  func bytes(_ symbol: String, count: Int) throws -> Data {
    guard !ambiguousSymbols.contains(symbol), let address = symbols[symbol], count > 0,
      count <= 1 << 20
    else {
      throw MisoError.invalid("Invalid or missing Mach-O symbol: \(symbol)")
    }
    let candidates = segments.filter {
      address >= $0.address && address - $0.address <= $0.size
        && UInt64(count) <= $0.size - (address - $0.address)
    }
    guard candidates.count == 1, let segment = candidates.first else {
      throw MisoError.invalid("Symbol has no unique file-backed segment")
    }
    let offset = Int(segment.offset + address - segment.address)
    return data.subdata(in: offset..<offset + count)
  }

  func blob(_ symbol: String) throws -> Data {
    let size = try bytes(symbol + "_size", count: 8).integer(at: 0, as: UInt64.self)
    guard size > 0, size <= 1 << 20 else { throw MisoError.invalid("Invalid Mach-O blob size") }
    return try bytes(symbol, count: Int(size))
  }

  static func string(_ data: Data, at offset: Int, limit: Int) throws -> String {
    guard offset >= 0, offset < limit, limit <= data.count,
      let end = data[offset..<min(limit, offset + 4096)].firstIndex(of: 0),
      let value = String(data: data[offset..<end], encoding: .utf8)
    else { throw MisoError.invalid("Invalid Mach-O string") }
    return value
  }
}

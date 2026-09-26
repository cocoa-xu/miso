import CMiso
import CryptoKit
import Foundation

public enum AuxiliaryStorage {
  public static let size = 0x2004000
  public static let panicLogOffset = 0x1504000
  public static let panicLogSize = 0x500000

  public struct BootSelection: Sendable {
    public let partitionType: UUID
    public let partitionIdentifier: UUID
    public let systemIdentifier: UUID

    public init(partitionType: UUID, partitionIdentifier: UUID, systemIdentifier: UUID) {
      self.partitionType = partitionType
      self.partitionIdentifier = partitionIdentifier
      self.systemIdentifier = systemIdentifier
    }

    public var value: String {
      [
        partitionType.gptBytes.uuidString, partitionIdentifier.gptBytes.uuidString,
        systemIdentifier.uuidString,
      ].joined(separator: ":").uppercased()
    }
  }

  public static func assemble(
    empty: Data, llb: Data, appleLogo: Data, nonces: Data, generator: UInt64,
    selection: BootSelection, profile: RestoreProfile
  ) throws -> Data {
    _ = try RestoreProfile.select(profile.release)
    guard empty.count == size, empty.dropFirst(0x4000).allSatisfy({ $0 == 0 }), nonces.count == 112,
      generator > 0
    else {
      throw MisoError.invalid("Invalid empty auxiliary storage or boot nonces")
    }
    guard !llb.isEmpty, !appleLogo.isEmpty, llb.count < 0x200000,
      appleLogo.count < 0x200000 - llb.count
    else {
      throw MisoError.invalid("Auxiliary firmware exceeds its flash region")
    }
    var flash = Data(repeating: 0xff, count: 0x2000000)
    var prefix = Data(count: 32)
    for (index, value) in [UInt32(0x4146_5548), 1, 1, 0x20000, 0, 0, 0, 0].enumerated() {
      prefix.put(value, at: index * 4)
    }
    flash.replaceSubrange(0..<64, with: prefix + SHA384.hash(data: prefix).prefix(32))
    flash.replaceSubrange(0x20000..<0x20000 + llb.count, with: llb)
    flash.replaceSubrange(
      0x20000 + llb.count..<0x20000 + llb.count + appleLogo.count, with: appleLogo)
    var misc = Data(count: 24)
    misc[0] = 1
    misc[1] = 1
    misc.put(UInt64(1), at: 12)
    let variables: [(String, Data)] = [
      ("boop-storage-nonces", nonces), ("boop-storage-misc", misc),
      ("com.apple.System.boot-nonce", Data(String(format: "0x%016llx", generator).utf8)),
      ("boot-volume", Data(selection.value.utf8)), ("auto-boot", Data("true".utf8)),
    ]
    for (index, generation) in [UInt32(5), 6].enumerated() {
      let bank = try NVRAM.encode(generation: generation, variables: variables)
      let decoded = try NVRAM.decode(bank)
      guard decoded.generation == generation,
        decoded.variables == Dictionary(uniqueKeysWithValues: variables)
      else {
        throw MisoError.invalid("NVRAM round-trip mismatch")
      }
      let offset = 0xa00000 + index * NVRAM.bankSize
      flash.replaceSubrange(offset..<offset + NVRAM.bankSize, with: bank)
    }
    let panicStart = panicLogOffset - 0x4000
    flash.replaceSubrange(panicStart..<panicStart + panicLogSize, with: Data(count: panicLogSize))
    let result = empty.prefix(0x4000) + flash
    try verifyPanicLog(result)
    return result
  }

  public static func verifyPanicLog(_ data: Data) throws {
    guard data.count == size,
      data[panicLogOffset..<panicLogOffset + panicLogSize].allSatisfy({ $0 == 0 })
    else {
      throw MisoError.invalid("Fresh auxiliary panic log must be zero-initialized")
    }
  }
}

enum NVRAM {
  static let bankSize = 0x80000
  static let regions: [(offset: Int, size: Int, signature: UInt8, name: String)] = [
    (0, 32, 0x5a, "nvram"), (32, 0x60000 - 32, 0x71, "common"), (0x60000, 0x20000, 0x70, "system"),
  ]

  static func headerChecksum(_ bytes: Data) -> UInt8 {
    var value = Int(bytes[0]) + bytes[2..<16].reduce(0) { $0 + Int($1) }
    while value > 255 { value = (value & 255) + (value >> 8) }
    return UInt8(value)
  }

  static func escaped(_ data: Data) -> Data {
    var result = Data()
    var cursor = 0
    while cursor < data.count {
      let byte = data[cursor]
      var count = 1
      if byte == 0 || byte == 255 {
        while cursor + count < data.count, data[cursor + count] == byte, count < 127 { count += 1 }
        result.append(contentsOf: [255, (byte & 128) | UInt8(count)])
      } else {
        result.append(byte)
      }
      cursor += count
    }
    result.append(0)
    return result
  }

  static func adler(_ data: Data) -> UInt32 {
    data.withUnsafeBytes {
      UInt32(adler32(1, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)))
    }
  }

  static func encode(generation: UInt32, variables: [(String, Data)]) throws -> Data {
    guard Set(variables.map(\.0)).count == variables.count else {
      throw MisoError.invalid("Duplicate NVRAM variables")
    }
    var payload = Data()
    for (key, value) in variables {
      guard !key.isEmpty, key.utf8.allSatisfy({ $0 > 0 && $0 < 128 && $0 != 61 }) else {
        throw MisoError.invalid("Invalid NVRAM variable name")
      }
      guard value.count <= 0x20000, key.utf8.count <= 1024 else {
        throw MisoError.invalid("Oversized NVRAM variable")
      }
      payload.append(contentsOf: key.utf8)
      payload.append(61)
      payload.append(escaped(value))
      guard payload.count < 0x20000 - 16 else {
        throw MisoError.invalid("NVRAM system region overflow")
      }
    }
    var result = Data(count: bankSize)
    for region in regions {
      var header = Data(count: 16)
      header[0] = region.signature
      header.put(UInt16(region.size / 16), at: 2)
      header.replaceSubrange(4..<4 + region.name.utf8.count, with: region.name.utf8)
      header[1] = headerChecksum(header)
      result.replaceSubrange(region.offset..<region.offset + 16, with: header)
    }
    result.put(generation, at: 20)
    result.replaceSubrange(0x60010..<0x60010 + payload.count, with: payload)
    result.put(adler(Data(result.dropFirst(20))), at: 16)
    return result
  }

  static func decode(_ data: Data) throws -> (generation: UInt32, variables: [String: Data]) {
    guard data.count == bankSize,
      try data.integer(at: 16, as: UInt32.self) == adler(Data(data.dropFirst(20)))
    else {
      throw MisoError.invalid("NVRAM bank checksum mismatch")
    }
    var variables: [String: Data] = [:]
    for region in regions {
      let header = data.subdata(in: region.offset..<region.offset + 16)
      let nameBytes = Array(region.name.utf8)
      guard header[0] == region.signature, header[1] == headerChecksum(header),
        try header.integer(at: 2, as: UInt16.self) == region.size / 16,
        Array(header[4..<4 + nameBytes.count]) == nameBytes,
        header.dropFirst(4 + nameBytes.count).allSatisfy({ $0 == 0 })
      else {
        throw MisoError.invalid("Invalid NVRAM region header")
      }
      if region.offset == 0 { continue }
      var cursor = region.offset + 16
      let end = region.offset + region.size
      while cursor < end, data[cursor] != 0 {
        guard let limit = data[cursor..<end].firstIndex(of: 0),
          let separator = data[cursor..<limit].firstIndex(of: 61), separator > cursor,
          let key = String(data: data[cursor..<separator], encoding: .ascii), variables[key] == nil
        else {
          throw MisoError.invalid("Invalid or duplicate NVRAM variable")
        }
        cursor = separator + 1
        var value = Data()
        while cursor < limit {
          let byte = data[cursor]
          cursor += 1
          if byte == 255 {
            guard cursor < limit, data[cursor] & 127 != 0 else {
              throw MisoError.invalid("Invalid NVRAM escape")
            }
            value.append(
              Data(repeating: data[cursor] & 128 == 0 ? 0 : 255, count: Int(data[cursor] & 127)))
            cursor += 1
          } else {
            value.append(byte)
          }
        }
        variables[key] = value
        cursor = limit + 1
      }
      guard data[cursor..<end].allSatisfy({ $0 == 0 }) else {
        throw MisoError.invalid("Unexpected NVRAM trailing bytes")
      }
    }
    return (try data.integer(at: 20), variables)
  }
}

extension Data {
  fileprivate var uuidString: String {
    precondition(count == 16)
    let hex = SafeFile.hex(self)
    let cuts = [0, 8, 12, 16, 20, 32]
    return zip(cuts, cuts.dropFirst()).map { start, end in
      String(
        hex[hex.index(hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)])
    }.joined(separator: "-")
  }
}

import CryptoKit
import Foundation

public enum DER {
  public struct Node: Sendable {
    public let tag: UInt8
    public let content: Data
    public let encoded: Data
  }

  public static func encode(_ tag: UInt8, _ content: Data) -> Data {
    var length = content.count
    var bytes = Data()
    if length < 128 {
      bytes.append(UInt8(length))
    } else {
      while length > 0 {
        bytes.insert(UInt8(truncatingIfNeeded: length), at: 0)
        length >>= 8
      }
      bytes.insert(0x80 | UInt8(bytes.count), at: 0)
    }
    return Data([tag]) + bytes + content
  }

  public static func nodes(_ input: Data) throws -> [Node] {
    let data = Data(input)
    var offset = 0
    var result: [Node] = []
    while offset < data.count {
      guard result.count < 100_000 else { throw MisoError.invalid("Too many DER nodes") }
      let start = offset
      let tag = data[offset]
      offset += 1
      if tag & 31 == 31 {
        var count = 0
        repeat {
          guard offset < data.count, count < 8,
            count != 0 || (data[offset] != 0x80 && data[offset] >= 31)
          else { throw MisoError.invalid("Invalid DER tag") }
          let value = data[offset]
          offset += 1
          count += 1
          if value & 128 == 0 { break }
        } while true
      }
      guard offset < data.count else { throw MisoError.invalid("Missing DER length") }
      var size = Int(data[offset])
      offset += 1
      if size & 128 != 0 {
        let count = size & 127
        guard count > 0, count <= 4, count <= data.count - offset, data[offset] != 0 else {
          throw MisoError.invalid("Invalid DER length")
        }
        size = data[offset..<offset + count].reduce(0) { ($0 << 8) | Int($1) }
        offset += count
        guard size >= 128 else { throw MisoError.invalid("Noncanonical DER length") }
      }
      guard size <= data.count - offset else { throw MisoError.invalid("Truncated DER value") }
      result.append(
        Node(
          tag: tag, content: data.subdata(in: offset..<offset + size),
          encoded: data.subdata(in: start..<offset + size)))
      offset += size
    }
    return result
  }

  public static func one(_ data: Data, tag: UInt8? = nil) throws -> Node {
    let values = try nodes(data)
    guard values.count == 1, let node = values.first, tag == nil || node.tag == tag else {
      throw MisoError.invalid("Unexpected DER shape")
    }
    return node
  }

  public static func integer(_ value: UInt64) -> Data {
    var number = value
    var bytes = Data()
    repeat {
      bytes.insert(UInt8(truncatingIfNeeded: number), at: 0)
      number >>= 8
    } while number > 0
    if bytes[0] & 128 != 0 { bytes.insert(0, at: 0) }
    return encode(2, bytes)
  }
}

public enum Image4 {
  public static func property(_ name: String, value: Data) throws -> Data {
    guard name.utf8.count == 4, name.utf8.allSatisfy({ $0 < 128 }) else {
      throw MisoError.invalid("Expected a four-character Image4 property")
    }
    var number = name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    var groups = Data([UInt8(number & 127)])
    number >>= 7
    while number > 0 {
      groups.insert(UInt8(number & 127) | 128, at: 0)
      number >>= 7
    }
    let content = DER.encode(0x30, DER.encode(0x16, Data(name.utf8)) + value)
    return Data([255]) + groups + DER.encode(0, content).dropFirst()
  }

  public static func properties(_ data: Data) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for node in try DER.nodes(DER.one(data, tag: 0x31).content) {
      guard node.tag == 255 else { throw MisoError.invalid("Unexpected Image4 property tag") }
      let pair = try DER.nodes(DER.one(node.content, tag: 0x30).content)
      guard pair.count == 2, pair[0].tag == 0x16, pair[0].content.count == 4,
        let name = String(data: pair[0].content, encoding: .ascii), result[name] == nil
      else { throw MisoError.invalid("Invalid or duplicate Image4 property") }
      guard try property(name, value: pair[1].encoded) == node.encoded else {
        throw MisoError.invalid("Image4 tag and property name disagree")
      }
      result[name] = pair[1].encoded
    }
    return result
  }

  public static func manifestProperties(_ data: Data) throws -> [String: Data] {
    let fields = try DER.nodes(DER.one(data, tag: 0x30).content)
    guard fields.count == 5, fields[0].tag == 0x16, fields[0].content == Data("IM4M".utf8),
      fields[1].tag == 2, fields[1].content == Data([0]),
      let body = try properties(fields[2].encoded)["MANB"]
    else { throw MisoError.invalid("Invalid Image4 manifest") }
    return try properties(body)
  }

  public static func manifestValue(_ ticket: Data, section: String, name: String) throws -> Data {
    guard let group = try manifestProperties(ticket)[section],
      let value = try properties(group)[name]
    else { throw MisoError.invalid("Missing Image4 manifest property") }
    return try DER.one(value).content
  }

  public static func payloadFields(_ data: Data) throws -> [DER.Node] {
    let fields = try DER.nodes(DER.one(data, tag: 0x30).content)
    guard fields.count >= 4, fields[0].tag == 0x16, fields[0].content == Data("IM4P".utf8),
      fields[1].tag == 0x16, fields[1].content.count == 4, fields[2].tag == 0x16,
      fields[3].tag == 4
    else { throw MisoError.invalid("Invalid Image4 payload") }
    return fields
  }

  public static func unwrap(_ data: Data) throws -> Data { try payloadFields(data)[3].content }

  public static func retype(_ data: Data, type: String) throws -> Data {
    guard type.utf8.count == 4, type.utf8.allSatisfy({ $0 < 128 }) else {
      throw MisoError.invalid("Invalid payload type")
    }
    let fields = try payloadFields(data)
    return DER.encode(
      0x30,
      fields[0].encoded + DER.encode(0x16, Data(type.utf8))
        + fields.dropFirst(2).reduce(Data()) { $0 + $1.encoded })
  }

  public static func stitch(payload: Data, ticket: Data, restore: Data? = nil) throws -> Data {
    _ = try payloadFields(payload)
    _ = try manifestProperties(ticket)
    var data = DER.encode(0x16, Data("IMG4".utf8)) + payload + DER.encode(0xa0, ticket)
    if let restore { data += DER.encode(0xa1, restore) }
    return DER.encode(0x30, data)
  }

  public static func verifyDigest(payload: Data, ticket: Data, type: String) throws {
    let expected = try manifestValue(ticket, section: type, name: "DGST")
    guard expected.count == 48, Data(SHA384.hash(data: payload)) == expected else {
      throw MisoError.invalid("Payload digest differs from manifest")
    }
  }

  public static func snapshotName(authBlob: Data) throws -> String {
    guard authBlob.count == 208, try authBlob.integer(at: 0, as: UInt32.self) == 2,
      try authBlob.integer(at: 4, as: UInt32.self) == 0,
      try authBlob.integer(at: 8, as: UInt32.self) == 1,
      try authBlob.integer(at: 12, as: UInt32.self) == 32
    else { throw MisoError.unsupported("System authentication blob") }
    return "com.apple.os.update-" + SafeFile.hex(authBlob[16..<48]).uppercased()
  }
}

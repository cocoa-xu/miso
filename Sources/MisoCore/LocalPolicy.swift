import CryptoKit
import Foundation
import Security

enum LocalPolicy {
  struct Signed {
    let image: Data
    let ticket: Data
    let measurement: Data
  }

  static func sortedSet(_ items: [Data]) -> Data {
    DER.encode(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +))
  }

  static func measurement(_ properties: [String: Data]) throws -> Data {
    let excluded: Set<String> = ["BNCH", "ECID", "lpnh", "ronh", "rpnh", "snon", "snuf", "srvn"]
    let ordered = try properties.map {
      (name: $0.key, bytes: try Image4.property($0.key, value: $0.value))
    }
    .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    var bytes = Data()
    for item in ordered {
      if excluded.contains(item.name) {
        var tag = Image4Trust.fourCC(item.name).littleEndian
        bytes.append(withUnsafeBytes(of: &tag) { Data($0) })
      } else {
        bytes.append(try DER.one(item.bytes).content)
      }
    }
    return Data(SHA384.hash(data: bytes))
  }

  static func certificates(_ data: Data, depth: Int = 0) throws -> [SecCertificate] {
    guard depth <= 16, data.count <= 1 << 20 else {
      throw MisoError.invalid("Certificate chain exceeds limits")
    }
    return try DER.nodes(data).flatMap { node in
      if let certificate = SecCertificateCreateWithData(nil, node.encoded as CFData) {
        return [certificate]
      }
      return node.tag & 0x20 != 0 ? try certificates(node.content, depth: depth + 1) : []
    }
  }

  static func key(_ material: Data, certificates chain: Data) throws -> P384.Signing.PrivateKey {
    let fields = try DER.nodes(DER.one(material, tag: 0x30).content)
    guard fields.count >= 2, fields[0].encoded == DER.integer(1), fields[1].tag == 4 else {
      throw MisoError.invalid("Invalid virtual policy SEC1 key")
    }
    let key = try P384.Signing.PrivateKey(rawRepresentation: fields[1].content)
    guard
      try certificates(chain).contains(where: {
        guard let publicKey = SecCertificateCopyKey($0),
          let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { return false }
        return bytes == key.publicKey.x963Representation
      })
    else { throw MisoError.invalid("Virtual policy certificate/key mismatch") }
    return key
  }

  static func sign(
    properties: [String: Data], payload: Data, key: P384.Signing.PrivateKey, chain: Data
  ) throws -> Signed {
    let required: Set<String> = [
      "BORD", "CHIP", "CPRO", "CSEC", "ECID", "SDOM", "CEPO", "lobo", "lpnh", "rpnh", "nsih",
      "vuid", "love", "kuid",
    ]
    let keys = Set(properties.keys)
    guard keys == required.union(["hrlp", "spih", "stng"]) || keys == required.union(["rolp"])
    else {
      throw MisoError.invalid("Unexpected local policy shape")
    }
    let fields = try Image4.payloadFields(payload)
    guard fields[1].content == Data("lpol".utf8) else {
      throw MisoError.invalid("Expected local policy payload")
    }
    let body = try sortedSet([
      Image4.property(
        "MANB",
        value: sortedSet([
          Image4.property(
            "MANP",
            value: sortedSet(properties.map { try Image4.property($0.key, value: $0.value) })),
          Image4.property(
            "lpol",
            value: sortedSet([
              Image4.property("DGST", value: DER.encode(4, Data(SHA384.hash(data: payload)))),
              Image4.property("EKEY", value: DER.encode(1, Data([0xFF]))),
            ])),
        ]))
    ])
    let signature = try key.signature(for: body)
    let ticket = DER.encode(
      0x30,
      DER.encode(0x16, Data("IM4M".utf8)) + DER.integer(0) + body
        + DER.encode(4, signature.derRepresentation) + DER.encode(0x30, chain))
    let image = try Image4.stitch(payload: payload, ticket: ticket)
    guard try verify(image, key: key.publicKey),
      let actual = try Image4Trust.authenticate(image, type: "lpol", decoder: .virtualPolicy),
      try actual == measurement(properties)
    else { throw MisoError.invalid("Independent/native policy verification mismatch") }
    return Signed(image: image, ticket: ticket, measurement: actual)
  }

  static func verify(_ image: Data, key: P384.Signing.PublicKey) throws -> Bool {
    let fields = try Image4Trust.fields(image)
    let manifest = try DER.nodes(DER.one(fields[2].content, tag: 0x30).content)
    guard manifest.count == 5, manifest[3].tag == 4 else {
      throw MisoError.invalid("Invalid policy signature")
    }
    let signature = try P384.Signing.ECDSASignature(derRepresentation: manifest[3].content)
    return key.isValidSignature(signature, for: manifest[2].encoded)
  }
}

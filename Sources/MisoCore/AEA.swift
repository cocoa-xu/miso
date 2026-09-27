import CryptoKit
import Foundation

public enum AEA {
  public struct Metadata: Sendable {
    public let fields: [String: Data]

    public init(header: Data, authenticatedData: Data) throws {
      guard header.count == 12, header.prefix(4) == Data("AEA1".utf8),
        try header.integer(at: 4, as: UInt32.self) == 1,
        try header.integer(at: 8, as: UInt32.self) == authenticatedData.count,
        !authenticatedData.isEmpty, authenticatedData.count <= 1 << 20
      else {
        throw MisoError.unsupported("AEA header or profile")
      }
      var fields: [String: Data] = [:]
      var offset = 0
      while offset < authenticatedData.count {
        let length = Int(try authenticatedData.integer(at: offset, as: UInt32.self))
        guard length >= 6, length <= authenticatedData.count - offset,
          let separator = authenticatedData[offset + 4..<offset + length].firstIndex(of: 0),
          separator > offset + 4,
          let name = String(data: authenticatedData[offset + 4..<separator], encoding: .utf8),
          fields[name] == nil
        else {
          throw MisoError.invalid("Invalid or duplicate AEA metadata entry")
        }
        fields[name] = authenticatedData.subdata(in: separator + 1..<offset + length)
        offset += length
      }
      self.fields = fields
    }

    public var keyURL: URL {
      get throws {
        guard let data = fields["com.apple.wkms.fcs-key-url"], data.count <= 4096,
          let string = String(data: data, encoding: .utf8), let url = URL(string: string),
          HTTPData.isAppleKeyURL(url)
        else {
          throw MisoError.invalid("AEA key URL is not an allowed Apple HTTPS endpoint")
        }
        return url
      }
    }

    public func symmetricKey(privateKeyPEM: Data) throws -> Data {
      struct Response: Decodable {
        let encapsulatedKey: String
        let wrappedKey: String
        enum CodingKeys: String, CodingKey {
          case encapsulatedKey = "enc-request"
          case wrappedKey = "wrapped-key"
        }
      }
      guard let responseData = fields["com.apple.wkms.fcs-response"],
        responseData.count <= 64 << 10,
        privateKeyPEM.count <= 64 << 10, let pem = String(data: privateKeyPEM, encoding: .utf8)
      else {
        throw MisoError.invalid("Missing AEA key response or invalid private key")
      }
      let response = try JSONDecoder().decode(Response.self, from: responseData)
      guard let encapsulated = Data(base64Encoded: response.encapsulatedKey),
        encapsulated.count == 65,
        let wrapped = Data(base64Encoded: response.wrappedKey), wrapped.count == 48
      else {
        throw MisoError.invalid("Invalid AEA wrapped-key shape")
      }
      let privateKey = try P256.KeyAgreement.PrivateKey(pemRepresentation: pem)
      var recipient = try HPKE.Recipient(
        privateKey: privateKey, ciphersuite: .P256_SHA256_AES_GCM_256,
        info: Data(), encapsulatedKey: encapsulated)
      let result = try recipient.open(wrapped)
      guard result.count == 32 else { throw MisoError.invalid("Invalid AEA symmetric key size") }
      return result
    }
  }

  public static func metadata(_ source: URL) throws -> Metadata {
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let header = try input.readExactly(12)
    let size = Int(try header.integer(at: 8, as: UInt32.self))
    guard size > 0, size <= 1 << 20 else {
      throw MisoError.invalid("AEA metadata size exceeds limit")
    }
    return try Metadata(header: header, authenticatedData: input.readExactly(size))
  }

  public static func decryptionKey(
    _ source: URL, privateKeyPEM: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> SymmetricKey {
    let metadata = try metadata(source)
    let pem: Data
    if let privateKeyPEM {
      pem = try SafeFile.read(privateKeyPEM, limit: 64 << 10)
    } else {
      pem = try await HTTPData.get(
        metadata.keyURL, maximumBytes: 64 << 10, cancellation: cancellation, redirects: .appleKeys)
    }
    try cancellation?.check()
    return try SymmetricKey(data: metadata.symmetricKey(privateKeyPEM: pem))
  }
}

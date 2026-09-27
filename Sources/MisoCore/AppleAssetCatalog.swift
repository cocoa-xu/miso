import CryptoKit
import Foundation
import Security

enum AppleAssetCatalog {
  static let audience = "02d8e57e-dd1c-4090-aa50-b4ed2aef0062"
  static let rootSHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"

  struct Asset: Codable, Equatable {
    let assetType: String
    let build: String
    let baseURL: URL
    let relativePath: String
    let downloadBytes: UInt64
    let expandedBytes: UInt64
    let measurement: Data
    let decryptionKey: String

    enum CodingKeys: String, CodingKey {
      case assetType = "AssetType"
      case build = "Build"
      case baseURL = "__BaseURL"
      case relativePath = "__RelativePath"
      case downloadBytes = "_DownloadSize"
      case expandedBytes = "_UnarchivedSize"
      case measurement = "_Measurement-SHA256"
      case decryptionKey = "ArchiveDecryptionKey"
    }

    var url: URL { baseURL.appendingPathComponent(relativePath) }
    var sha256: String { SafeFile.hex(measurement) }

    func validate(assetType expectedType: String, build expectedBuild: String) throws {
      guard assetType == expectedType, build == expectedBuild,
        baseURL.absoluteString.hasSuffix("/"), isArchiveURL(url),
        try SafeFile.relativePath(relativePath) == relativePath,
        relativePath.hasPrefix(assetType.replacingOccurrences(of: ".", with: "_") + "/"),
        measurement.count == 32,
        let key = Data(base64Encoded: decryptionKey), key.count == 32,
        (1...(32 << 30)).contains(downloadBytes),
        (1...(64 << 30)).contains(expandedBytes)
      else { throw MisoError.invalid("Apple asset identity, URL, digest or size mismatch") }
    }
  }

  static func isArchiveURL(_ url: URL) -> Bool {
    url.scheme == "https" && url.host == "updates.cdn-apple.com" && url.port == nil
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && url.path.range(
        of:
          #"\A/[A-Za-z0-9_-]+/mobileassets/[A-Za-z0-9_-]+/[A-Fa-f0-9-]{36}/com_apple_MobileAsset_[A-Za-z0-9_]+/[A-Fa-f0-9-]{36}\.aar\z"#,
        options: .regularExpression) != nil
  }

  static func verify(_ response: Data, at date: Date = Date()) throws -> Data {
    guard response.count <= 8 << 20, let text = String(data: response, encoding: .utf8) else {
      throw MisoError.invalid("Invalid Apple asset response size or encoding")
    }
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
      separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else {
      throw MisoError.invalid("Expected a signed Apple asset response")
    }
    struct Header: Decodable {
      let alg: String
      let x5c: [Data]
    }
    let header = try JSONDecoder().decode(Header.self, from: base64URL(parts[0]))
    guard header.alg == "ES256", (2...4).contains(header.x5c.count) else {
      throw MisoError.invalid("Unsupported Apple asset signature")
    }
    let certificates = try header.x5c.map { der -> SecCertificate in
      guard der.count <= 16 << 10,
        let certificate = SecCertificateCreateWithData(nil, der as CFData)
      else { throw MisoError.invalid("Invalid Apple asset certificate") }
      return certificate
    }
    var trust: SecTrust?
    guard
      SecTrustCreateWithCertificates(
        certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust
    else { throw MisoError.invalid("Cannot evaluate Apple asset certificate trust") }
    SecTrustSetNetworkFetchAllowed(trust, false)
    SecTrustSetVerifyDate(trust, date as CFDate)
    guard SecTrustEvaluateWithError(trust, nil),
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let root = chain.last,
      SafeFile.hex(SHA256.hash(data: SecCertificateCopyData(root) as Data)) == rootSHA256,
      SecCertificateCopySubjectSummary(certificates[0]) as String? == "Pallas ECDH SIGN PROD",
      let key = SecCertificateCopyKey(certificates[0]),
      let rawKey = SecKeyCopyExternalRepresentation(key, nil)
    else { throw MisoError.invalid("Apple asset signing chain rejected") }
    let signature = try P256.Signing.ECDSASignature(derRepresentation: base64URL(parts[2]))
    let publicKey = try P256.Signing.PublicKey(x963Representation: rawKey as Data)
    guard publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)) else {
      throw MisoError.invalid("Apple asset response signature rejected")
    }
    return try base64URL(parts[1])
  }

  static func select(_ payload: Data, assetType: String, build: String) throws -> Asset {
    struct Catalog: Decodable {
      let audience: String
      let assets: [Asset]
      enum CodingKeys: String, CodingKey {
        case audience = "AssetAudience"
        case assets = "Assets"
      }
    }
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    guard catalog.audience == audience, catalog.assets.count == 1,
      let asset = catalog.assets.first
    else { throw MisoError.invalid("Expected one exact-build Apple asset") }
    try asset.validate(assetType: assetType, build: build)
    return asset
  }

  static func fetchMetal(
    build: String, journal: ExecutionJournal
  ) async throws -> Asset {
    var configuration = XcodeConfiguration()
    configuration.build = build
    try configuration.validate()
    let type = "com.apple.MobileAsset.MetalToolchain"
    let host = journal.record.host
    let body = try JSONSerialization.data(withJSONObject: [
      "ClientVersion": 2, "AssetType": type, "AssetAudience": audience, "RequestedBuild": build,
      "ProductType": "Mac", "HWModelStr": "", "ProductVersion": host.productVersion,
      "BuildVersion": host.productBuild,
    ])
    try SafeFile.writeNew(body, to: journal.output.appendingPathComponent("request.json"))
    let response = journal.output.appendingPathComponent("catalog.jwt")
    try await HTTPFile.post(
      URL(string: "https://gdmf.apple.com/v2/assets")!, body: body, contentType: "application/json",
      to: response, maximumBytes: 8 << 20, cancellation: journal.cancellation)
    let payload = try verify(SafeFile.read(response, limit: 8 << 20))
    try SafeFile.writeNew(payload, to: journal.output.appendingPathComponent("catalog.json"))
    return try select(payload, assetType: type, build: build)
  }

  static func base64URL(_ text: Substring) throws -> Data {
    guard !text.isEmpty,
      text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
      text.count % 4 != 1
    else { throw MisoError.invalid("Invalid signed response encoding") }
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let bytes = Data(base64Encoded: value) else {
      throw MisoError.invalid("Invalid signed response encoding")
    }
    return bytes
  }
}

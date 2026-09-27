import Foundation
import Testing

@testable import MisoCore

private func signedMetalCatalog() throws -> Data {
  let url = try #require(
    Bundle.module.url(forResource: "metal-27A266a", withExtension: "jwt", subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

private func assetVerificationDate() throws -> Date {
  try #require(ISO8601DateFormatter().date(from: "2026-10-03T14:00:00Z"))
}

@Test func appleAssetCatalogAuthenticatesAndSelectsTheExactBuild() throws {
  let payload = try AppleAssetCatalog.verify(signedMetalCatalog(), at: assetVerificationDate())
  let asset = try AppleAssetCatalog.select(
    payload, assetType: "com.apple.MobileAsset.MetalToolchain", build: "27A266a")
  #expect(asset.downloadBytes == 838_860_800)
  #expect(asset.sha256 == "12e44e8047ca8ace6af3ff76d2800e4c45b2e245f15c24feeb4757400ee9ef09")
  #expect(AppleAssetCatalog.isArchiveURL(asset.url))
  #expect(throws: MisoError.self) {
    try AppleAssetCatalog.select(
      payload, assetType: "com.apple.MobileAsset.MetalToolchain", build: "27A9269")
  }
}

@Test func appleAssetCatalogRejectsTamperingAndExpiredCertificates() throws {
  let original = try signedMetalCatalog()
  let parts = String(decoding: original, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
  var changed = try AppleAssetCatalog.base64URL(parts[1])
  changed[changed.count / 2] ^= 1
  let encoded = changed.base64EncodedString().replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  let tampered = Data((parts[0] + "." + encoded + "." + parts[2]).utf8)
  #expect(throws: (any Error).self) {
    try AppleAssetCatalog.verify(tampered, at: assetVerificationDate())
  }
  #expect(throws: MisoError.self) {
    try AppleAssetCatalog.verify(original, at: Date(timeIntervalSince1970: 0))
  }
  #expect(throws: (any Error).self) { try AppleAssetCatalog.verify(Data("a.b.c".utf8)) }
}

@Test(arguments: ["__BaseURL", "__RelativePath", "_Measurement-SHA256", "ArchiveDecryptionKey"])
func appleAssetCatalogRejectsUnsafeAssetFields(_ field: String) throws {
  let payload = try AppleAssetCatalog.verify(signedMetalCatalog(), at: assetVerificationDate())
  var catalog = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
  var assets = try #require(catalog["Assets"] as? [[String: Any]])
  assets[0][field] = field == "__BaseURL" ? "https://example.com/" : "../invalid"
  catalog["Assets"] = assets
  let changed = try JSONSerialization.data(withJSONObject: catalog)
  #expect(throws: (any Error).self) {
    try AppleAssetCatalog.select(
      changed, assetType: "com.apple.MobileAsset.MetalToolchain", build: "27A266a")
  }
}

@Test func largeDownloadsAreLimitedToAppleAssetArchives() throws {
  let payload = try AppleAssetCatalog.verify(signedMetalCatalog(), at: assetVerificationDate())
  let asset = try AppleAssetCatalog.select(
    payload, assetType: "com.apple.MobileAsset.MetalToolchain", build: "27A266a")
  try HTTPFile.validate(asset.url, maximumBytes: 16 << 30, appleAsset: true)
  #expect(throws: MisoError.self) { try HTTPFile.validate(asset.url, maximumBytes: 16 << 30) }
  #expect(throws: MisoError.self) {
    try HTTPFile.validate(asset.url, maximumBytes: 33 << 30, appleAsset: true)
  }
  #expect(throws: MisoError.self) {
    try HTTPFile.validate(
      URL(string: "https://example.com/asset.aar")!, maximumBytes: 1 << 30, appleAsset: true)
  }
}

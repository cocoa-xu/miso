import Foundation
import Testing

@testable import MisoCore

private let catalogRevision = String(repeating: "a", count: 40)

private func catalogEntry(_ name: String, revision: String = catalogRevision) -> [String: Any] {
  ["name": name, "tap": "homebrew/core", "tap_git_head": revision]
}

private func catalogData(_ entries: [[String: Any]]) throws -> Data {
  try JSONSerialization.data(withJSONObject: entries)
}

private final class CatalogHTTPProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    do {
      let entries = (0..<1_100).map { index in
        var entry = catalogEntry("formula-\(index)")
        entry["description"] = String(repeating: "x", count: 8_192)
        return entry
      }
      let bytes = try catalogData(entries)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(bytes.count)])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: bytes)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}

@Test func formulaCatalogDownloadSupportsLargerThanMetadataResponses() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("catalog.json")
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [CatalogHTTPProtocol.self]
  let catalog = try await HomebrewFormulaCatalog.download(to: output, configuration: configuration)
  #expect(catalog.count == 1_100)
  #expect(catalog.revision == catalogRevision)
  #expect(try Data(contentsOf: output).count > 8 << 20)
  #expect(throws: (any Error).self) { try catalog.document("missing") }
}

@Test func formulaCatalogPreservesOneSnapshotAndSelectedMetadata() throws {
  var entry = catalogEntry("node@24")
  entry["versions"] = ["stable": "24.9.0"]
  let catalog = try HomebrewFormulaCatalog(catalogData([entry, catalogEntry("gettext")]))
  #expect(catalog.count == 2)
  #expect(catalog.revision == catalogRevision)
  let decoded = try #require(
    JSONSerialization.jsonObject(with: catalog.document("node@24")) as? [String: Any])
  #expect(NSDictionary(dictionary: decoded).isEqual(to: entry))
  #expect(throws: (any Error).self) { try catalog.document("absent") }
}

@Test func formulaCatalogRejectsMixedSnapshotsAndDuplicateNames() throws {
  let original = catalogEntry("gh")
  for entries in [
    [original, catalogEntry("gettext", revision: String(repeating: "b", count: 40))],
    [original, original], [], [catalogEntry("../outside")],
    [catalogEntry("gh", revision: "invalid")],
  ] {
    #expect(throws: (any Error).self) { try HomebrewFormulaCatalog(catalogData(entries)) }
  }
  #expect(throws: (any Error).self) { try HomebrewFormulaCatalog(Data("{}".utf8)) }
}

@Test func formulaCatalogRejectsForeignTapsAndVariationRevisionOverrides() throws {
  var foreign = catalogEntry("gh")
  foreign["tap"] = "other/core"
  #expect(throws: (any Error).self) { try HomebrewFormulaCatalog(catalogData([foreign])) }
  var entry = catalogEntry("gh")
  entry["variations"] = ["arm64_golden_gate": ["tap_git_head": String(repeating: "b", count: 40)]]
  #expect(throws: (any Error).self) { try HomebrewFormulaCatalog(catalogData([entry])) }
  entry["variations"] = ["arm64_golden_gate": ["tap_git_head": catalogRevision]]
  #expect(try HomebrewFormulaCatalog(catalogData([entry])).revision == catalogRevision)
}

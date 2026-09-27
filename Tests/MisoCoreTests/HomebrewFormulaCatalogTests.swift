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

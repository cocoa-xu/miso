import Foundation

struct HomebrewFormulaCatalog {
  static let maximumBytes = 64 << 20
  let revision: String
  private let documents: [String: Data]

  var count: Int { documents.count }

  init(_ data: Data) throws {
    guard data.count <= Self.maximumBytes,
      let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      !entries.isEmpty, entries.count <= 20_000
    else { throw MisoError.invalid("Invalid Homebrew formula catalog") }
    var documents: [String: Data] = [:]
    var revision: String?
    for entry in entries {
      guard let name = entry["name"] as? String,
        entry["tap"] as? String == "homebrew/core",
        let commit = entry["tap_git_head"] as? String,
        documents[name] == nil
      else { throw MisoError.invalid("Invalid or duplicate formula catalog entry") }
      try PackageRequest(name: name).validate()
      _ = try GitRemote.objectID(commit)
      guard revision == nil || revision == commit else {
        throw MisoError.invalid("Formula catalog spans multiple core snapshots")
      }
      for variation in (entry["variations"] as? [String: [String: Any]] ?? [:]).values {
        if let override = variation["tap_git_head"] {
          guard override as? String == commit else {
            throw MisoError.invalid("Formula variation differs from catalog snapshot")
          }
        }
      }
      revision = commit
      let bytes = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
      guard bytes.count <= 8 << 20 else {
        throw MisoError.invalid("Formula catalog entry exceeds limit")
      }
      documents[name] = bytes
    }
    guard let revision else { throw MisoError.invalid("Missing formula catalog revision") }
    self.revision = revision
    self.documents = documents
  }

  func document(_ name: String) throws -> Data {
    guard let bytes = documents[name] else {
      throw MisoError.unsupported("Formula is absent from the catalog: \(name)")
    }
    return bytes
  }
}

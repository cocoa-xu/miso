import Foundation

enum XcodeAndroidLicenses {
  static let base = URL(string: "https://dl.google.com/android/repository/")!

  static func document(_ data: Data) throws -> XMLElement {
    guard data.count <= 8 << 20, let text = String(data: data, encoding: .utf8),
      !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY"),
      let root = try XMLDocument(
        data: data,
        options: [
          .nodeLoadExternalEntitiesNever,
          .nodePreserveWhitespace,
        ]
      ).rootElement()
    else { throw MisoError.invalid("Invalid Android license catalog") }
    return root
  }

  static func sites(_ data: Data) throws -> [String] {
    let root = try document(data)
    guard root.localName == "site-list",
      root.uri == "http://schemas.android.com/repository/android/sites-common/1"
    else { throw MisoError.invalid("Invalid Android catalog site list") }
    let paths = try root.elements(forName: "site").map { site in
      guard let path = site.elements(forName: "url").first?.stringValue,
        path.hasSuffix(".xml"), path.utf8.count < 512,
        path.range(of: #"\A[A-Za-z0-9_./-]+\z"#, options: .regularExpression) != nil
      else { throw MisoError.invalid("Unsafe Android catalog path") }
      _ = try SafeFile.relativePath(path)
      return path
    }
    guard !paths.isEmpty, paths.count <= 64, Set(paths).count == paths.count else {
      throw MisoError.invalid("Invalid Android catalog count")
    }
    return paths
  }

  static func hashes(_ data: Data) throws -> [String: Set<String>] {
    let root = try document(data)
    var result: [String: Set<String>] = [:]
    for license in root.elements(forName: "license") {
      guard let id = license.attribute(forName: "id")?.stringValue,
        id.range(of: #"\A[a-z][a-z0-9-]{0,127}\z"#, options: .regularExpression) != nil,
        let text = license.stringValue, !text.isEmpty, text.utf8.count <= 1 << 20
      else { throw MisoError.invalid("Invalid Android license identity or terms") }
      result[id, default: []].insert(XcodeAndroidMetadata.licenseDigest(text))
      result[id, default: []].insert(
        XcodeAndroidMetadata.licenseDigest(
          text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return result
  }

  static func prepare(
    output: URL, previous: [ImageBundle.FileRecord]?, cache: URL?,
    cancellation: CancellationToken
  ) async throws -> [ImageBundle.FileRecord] {
    let directory = output.appendingPathComponent("license-catalogs")
    try SafeFile.makeDirectory(directory)
    if let cache {
      guard let previous, !previous.isEmpty else {
        throw MisoError.invalid("Android cache predates license catalogs; prepare fresh inputs")
      }
      return try previous.map { record in
        let data = try SafeFile.read(Artifacts.resolve(record, under: cache), limit: 8 << 20)
        let target = directory.appendingPathComponent(
          URL(fileURLWithPath: record.path).lastPathComponent)
        try SafeFile.writeNew(data, to: target)
        let copied = try Artifacts.record(target, relativeTo: output)
        guard copied == record else {
          throw MisoError.invalid("Android license catalog cache changed")
        }
        return copied
      }
    }
    let sitesData = try await HTTPData.get(
      base.appendingPathComponent("addons_list-6.xml"),
      maximumBytes: 1 << 20, cancellation: cancellation)
    let paths = try sites(sitesData)
    var records: [ImageBundle.FileRecord] = []
    for (index, path) in paths.enumerated() {
      let data = try await HTTPData.get(
        base.appendingPathComponent(path),
        maximumBytes: 8 << 20, cancellation: cancellation)
      _ = try hashes(data)
      let target = directory.appendingPathComponent("\(index).xml")
      try SafeFile.writeNew(data, to: target)
      records.append(try Artifacts.record(target, relativeTo: output))
    }
    return records
  }
}

import Foundation

public enum BaseTapInputs {
  public struct Formula: Codable {
    let name: String
    let version: String
    let revision: Int
    let payload: ImageBundle.FileRecord

    var kegVersion: String { version + (revision == 0 ? "" : "_\(revision)") }
  }

  public struct Tap: Codable {
    let name: String
    let revision: String
    let resource: String
    let path: String
    let formulas: [Formula]

    var destination: String {
      let parts = name.split(separator: "/")
      return "opt/homebrew/Library/Taps/\(parts[0])/homebrew-\(parts[1])"
    }
  }

  public struct Plan: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let archive: ImageBundle.FileRecord
    let taps: [Tap]

    func validate() throws {
      _ = try RestoreProfile.select(target)
      guard schemaVersion == 1, (1...32).contains(taps.count),
        Set(taps.map(\.name)).count == taps.count,
        (1...(64 << 20)).contains(archive.bytes)
      else { throw MisoError.invalid("Invalid tap plan") }
      _ = try SafeFile.relativePath(archive.path)
      try SafeFile.validateSHA256(archive.sha256)
      var names = Set<String>()
      for tap in taps {
        guard
          tap.name.range(
            of: #"\A[a-z0-9][a-z0-9_-]{0,63}/[a-z0-9][a-z0-9_-]{0,63}\z"#,
            options: .regularExpression) != nil,
          tap.revision.range(of: #"\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z"#, options: .regularExpression)
            != nil,
          tap.resource.range(of: #"\A[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression)
            != nil,
          (1...64).contains(tap.formulas.count)
        else { throw MisoError.invalid("Invalid tap identity") }
        _ = try SafeFile.relativePath(tap.path)
        for formula in tap.formulas {
          try PackageRequest(name: formula.name, version: formula.version).validate()
          guard names.insert(formula.name).inserted, (0...100_000).contains(formula.revision),
            formula.payload.bytes > 0, formula.payload.bytes <= 512 << 20
          else { throw MisoError.invalid("Duplicate or invalid tap formula") }
          _ = try SafeFile.relativePath(formula.payload.path)
          try SafeFile.validateSHA256(formula.payload.sha256)
        }
      }
    }
  }

  static func subtree(_ entries: [BaseInputArchive.Entry], path: String) throws -> [BaseInputArchive
    .Entry]
  {
    _ = try SafeFile.relativePath(path)
    let result = entries.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map {
      BaseInputArchive.Entry(
        path: $0.path == path ? "." : String($0.path.dropFirst(path.count + 1)),
        kind: $0.kind, mode: $0.mode, bytes: $0.bytes, sha256: $0.sha256, link: $0.link)
    }.sorted { $0.path < $1.path }
    guard result.first?.path == ".", result.first?.kind == "directory",
      result.allSatisfy({ $0.kind != "symlink" }),
      result.contains(where: { $0.path == ".git/HEAD" && $0.kind == "file" })
    else { throw MisoError.invalid("Expected a symlink-free tap checkout snapshot") }
    return result
  }

  static func tree(_ tap: Tap, inputs: URL) throws -> URL {
    let resource = "resources/" + tap.resource + "/" + tap.path
    return try GuestVolume(inputs).directory(resource).url
  }

  public static func verify(plan url: URL, inputs: URL, cancellation: CancellationToken? = nil)
    throws -> Plan
  {
    let plan = try JSON.read(Plan.self, from: url)
    try plan.validate()
    let archive = try Artifacts.resolve(plan.archive, under: inputs, cancellation: cancellation)
    let manifest = try JSON.read(BaseInputArchive.Manifest.self, from: archive)
    guard manifest.schemaVersion == 1 else {
      throw MisoError.unsupported("Tap input archive schema")
    }
    for tap in plan.taps {
      let snapshots = manifest.resources.filter { $0.name == tap.resource }
      guard snapshots.count == 1 else {
        throw MisoError.invalid("Missing or ambiguous tap snapshot")
      }
      let expected = try subtree(snapshots[0].entries, path: tap.path)
      guard
        try BaseInputArchive.inventory(tree(tap, inputs: inputs), cancellation: cancellation)
          == expected
      else {
        throw MisoError.invalid("Tap checkout differs from the archived snapshot: \(tap.name)")
      }
      for formula in tap.formulas {
        let payload = try Artifacts.resolve(
          formula.payload, under: inputs, cancellation: cancellation)
        _ = try TarPayload.inspect(payload, cancellation: cancellation)
      }
    }
    return plan
  }
}

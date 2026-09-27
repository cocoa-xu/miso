import CryptoKit
import Foundation

public enum HomebrewResolution {
  public struct Bottle: Codable, Equatable, Sendable {
    public let tag: String
    public let url: URL
    public let sha256: String
    public let cellar: String
    public let rebuild: Int
  }

  public struct Formula: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let revision: Int
    public let dependencies: [String]
    public let systemDependencies: [String]
    public let bottle: Bottle
    public let sourceURL: URL
    public let sourceSHA256: String
    public let metadataSHA256: String
    public let tapCommit: String
    public let kegOnly: Bool
    public let hasPostInstall: Bool
  }

  public struct Receipt: Codable, Sendable {
    public let schemaVersion: Int
    public let target: MacOSRelease
    public let requests: [PackageRequest]
    public let selectedRoots: [String: String]
    public let formulae: [String: Formula]
    public let installOrder: [String]
    public let metadata: [ImageBundle.FileRecord]
    public let payloadsIncluded: Bool
    public let installationVerified: Bool
    public let completeBaseResolution: Bool
  }

  private static let macOSMajors: [String: Int] = [
    "high_sierra": 10, "mojave": 10, "catalina": 10, "big_sur": 11,
    "monterey": 12, "ventura": 13, "sonoma": 14, "sequoia": 15,
    "tahoe": 26, "golden_gate": 27,
  ]

  static func tag(for target: MacOSRelease) throws -> String {
    let major = try MacOSVersion(target.version).major
    guard [15, 26, 27].contains(major),
      let name = macOSMajors.first(where: { $0.value == major })?.key
    else { throw MisoError.unsupported("Homebrew target macOS \(target.version)") }
    return "arm64_" + name
  }

  static func parse(_ bytes: Data, name: String, target: MacOSRelease) throws -> Formula {
    try PackageRequest(name: name).validate()
    let tag = try tag(for: target)
    let original = try object(bytes)
    guard original["name"] as? String == name else {
      throw MisoError.invalid("Formula metadata identity mismatch: \(name)")
    }
    let variation = (original["variations"] as? [String: [String: Any]])?[tag] ?? [:]
    let value = original.merging(variation) { _, new in new }
    guard value["disabled"] as? Bool == false else {
      throw MisoError.unsupported("disabled formula \(name)")
    }
    guard let versions = value["versions"] as? [String: Any],
      let version = versions["stable"] as? String,
      let revision = value["revision"] as? Int, revision >= 0,
      var dependencies = value["dependencies"] as? [String],
      let kegOnly = value["keg_only"] as? Bool,
      let requirements = value["requirements"] as? [[String: Any]],
      let source = value["ruby_source_path"] as? String,
      let checksum = (value["ruby_source_checksum"] as? [String: Any])?["sha256"] as? String,
      let commit = value["tap_git_head"] as? String,
      commit.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil
    else { throw MisoError.invalid("Incomplete formula metadata: \(name)") }
    try PackageRequest(name: name, version: version).validate()
    try SafeFile.validateSHA256(checksum)
    _ = try SafeFile.relativePath(source)
    guard source.hasPrefix("Formula/"), source.hasSuffix(".rb") else {
      throw MisoError.invalid("Unexpected formula source path")
    }
    try compatible(requirements, target: target)
    let builtins = value["uses_from_macos"] as? [Any] ?? []
    let bounds = value["uses_from_macos_bounds"] as? [[String: String]] ?? []
    guard builtins.count == bounds.count else {
      throw MisoError.invalid("Incomplete macOS dependency bounds")
    }
    var systemDependencies: [String] = []
    for (dependency, bound) in zip(builtins, bounds) {
      let dependencyName: String
      if let string = dependency as? String {
        dependencyName = string
      } else if let item = dependency as? [String: Any], item.count == 1, let key = item.keys.first
      {
        let scopes = (item[key] as? [String]) ?? (item[key] as? String).map { [$0] } ?? []
        guard !scopes.isEmpty, Set(scopes).isSubset(of: ["build", "test", "run"]) else {
          throw MisoError.unsupported("macOS dependency scope")
        }
        if !scopes.contains("run") { continue }
        dependencyName = key
      } else {
        throw MisoError.invalid("Invalid macOS dependency")
      }
      guard Set(bound.keys).isSubset(of: ["since"]),
        bound["since"].map({ macOSMajors[$0] != nil }) ?? true
      else { throw MisoError.unsupported("macOS dependency bound") }
      if let since = bound["since"], let major = macOSMajors[since],
        major > (try MacOSVersion(target.version).major)
      {
        dependencies.append(dependencyName)
      } else {
        systemDependencies.append(dependencyName)
      }
    }
    dependencies = Array(Set(dependencies)).sorted()
    for name in dependencies + systemDependencies { try PackageRequest(name: name).validate() }
    guard let stable = (value["bottle"] as? [String: Any])?["stable"] as? [String: Any],
      let bottles = stable["files"] as? [String: [String: Any]],
      let bottle = bottles[tag] ?? bottles["all"],
      let urlString = bottle["url"] as? String, let url = URL(string: urlString),
      url.scheme == "https", url.host == "ghcr.io", url.user == nil, url.password == nil,
      url.port == nil, url.query == nil, url.fragment == nil,
      let digest = bottle["sha256"] as? String, let cellar = bottle["cellar"] as? String,
      [":any", ":any_skip_relocation", "any", "any_skip_relocation", "/opt/homebrew/Cellar"]
        .contains(cellar),
      let rebuild = stable["rebuild"] as? Int, rebuild >= 0
    else {
      throw MisoError.unsupported("no compatible arm64 bottle for \(name) on \(target.version)")
    }
    try SafeFile.validateSHA256(digest)
    guard
      url == (try HomebrewRegistry.blob(name: name, sha256: digest))
    else {
      throw MisoError.invalid("Bottle URL identity mismatch")
    }
    let hooks = value["post_install_defined"] as? Bool
    let steps = value["post_install_steps"] as? [Any]
    guard hooks != nil || steps != nil else {
      throw MisoError.invalid("Missing formula lifecycle metadata")
    }
    return Formula(
      name: name, version: version, revision: revision, dependencies: dependencies,
      systemDependencies: systemDependencies.sorted(),
      bottle: Bottle(
        tag: bottles[tag] != nil ? tag : "all", url: url, sha256: digest,
        cellar: cellar, rebuild: rebuild),
      sourceURL: URL(
        string: "https://raw.githubusercontent.com/Homebrew/homebrew-core/\(commit)/\(source)")!,
      sourceSHA256: checksum, metadataSHA256: SafeFile.hex(SHA256.hash(data: bytes)),
      tapCommit: commit, kegOnly: kegOnly,
      hasPostInstall: hooks == true || !(steps ?? []).isEmpty)
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw MisoError.invalid("Expected formula metadata object")
    }
    return value
  }

  static func compatible(_ requirements: [[String: Any]], target: MacOSRelease) throws {
    let targetVersion = try MacOSVersion(target.version)
    for item in requirements {
      if let contexts = item["contexts"] as? [String], !contexts.isEmpty,
        Set(contexts).isSubset(of: ["build", "test"])
      {
        continue
      }
      if let specs = item["specs"] as? [String], !specs.isEmpty, !specs.contains("stable") {
        continue
      }
      guard let name = item["name"] as? String else {
        throw MisoError.invalid("Missing requirement name")
      }
      let version = item["version"] as? String
      switch name {
      case "macos":
        if let version {
          let minimum: MacOSVersion
          if let major = macOSMajors[version] {
            minimum = try MacOSVersion("\(major).0")
          } else {
            minimum = try MacOSVersion(version.contains(".") ? version : version + ".0")
          }
          guard targetVersion >= minimum else {
            throw MisoError.unsupported("formula requires macOS \(version)")
          }
        }
      case "arch":
        guard ["arm64", ":arm64"].contains(version ?? "") else {
          throw MisoError.unsupported("formula requires a different architecture")
        }
      default: throw MisoError.unsupported("formula runtime requirement \(name)")
      }
    }
  }

  static func installOrder(_ formulae: [String: Formula], roots: [String]) throws -> [String] {
    var visiting = Set<String>()
    var visited = Set<String>()
    var order: [String] = []
    func visit(_ name: String) throws {
      if visited.contains(name) { return }
      guard visiting.insert(name).inserted, let formula = formulae[name] else {
        throw MisoError.invalid("Cyclic or incomplete formula dependency graph")
      }
      for dependency in formula.dependencies.sorted() { try visit(dependency) }
      visiting.remove(name)
      visited.insert(name)
      order.append(name)
    }
    for root in roots.sorted() { try visit(root) }
    guard visited == Set(formulae.keys) else {
      throw MisoError.invalid("Unreachable formula in resolution")
    }
    return order
  }

  public static func run(
    requests: [PackageRequest], target: MacOSRelease, output: URL, metadata: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard !requests.isEmpty, requests.count <= 256,
      Set(requests.map(\.name)).count == requests.count
    else {
      throw MisoError.invalid("Expected unique Homebrew formula requests")
    }
    for request in requests { try request.validate() }
    _ = try tag(for: target)
    if let metadata { _ = try GuestVolume(metadata) }
    let journal = try ExecutionJournal(
      output: output, operation: "resolve-base-formulae", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: target)
      try journal.setMetadata("requests", value: requests)
      let directory = journal.output.appendingPathComponent("metadata")
      try SafeFile.makeDirectory(directory)
      var documents: [String: Data] = [:]
      var catalog: HomebrewFormulaCatalog?
      func document(_ name: String) async throws -> Data {
        try PackageRequest(name: name).validate()
        if let data = documents[name] { return data }
        guard documents.count < 1024 else {
          throw MisoError.invalid("Formula resolution exceeds limit")
        }
        try journal.cancellation.check()
        let data: Data
        if let metadata {
          data = try SafeFile.read(try GuestVolume(metadata).path(name + ".json"), limit: 8 << 20)
        } else {
          if catalog == nil {
            let archive = journal.output.appendingPathComponent("catalog.json")
            let snapshot = try await HomebrewFormulaCatalog.download(
              to: archive, cancellation: journal.cancellation)
            try journal.setMetadata(
              "catalog", value: Artifacts.record(archive, relativeTo: journal.output))
            try journal.setMetadata("catalogRevision", value: snapshot.revision)
            try journal.setMetadata("catalogFormulaCount", value: snapshot.count)
            catalog = snapshot
          }
          guard let catalog else { throw MisoError.invalid("Missing formula catalog") }
          data = try catalog.document(name)
        }
        try SafeFile.writeNew(data, to: directory.appendingPathComponent(name + ".json"))
        documents[name] = data
        return data
      }
      var formulae: [String: Formula] = [:]
      var roots: [String: String] = [:]
      func closure(_ root: Formula) async throws -> [String: Formula] {
        var resolved = [root.name: root]
        var pending = root.dependencies
        while let name = pending.popLast() {
          if resolved[name] != nil { continue }
          let formula = try parse(await document(name), name: name, target: target)
          resolved[name] = formula
          pending += formula.dependencies
        }
        _ = try installOrder(resolved, roots: [root.name])
        return resolved
      }
      for request in requests {
        let data = try await document(request.name)
        let original = try object(data)
        do {
          let primary = try parse(data, name: request.name, target: target)
          if request.version == nil || request.version == primary.version {
            let resolved = try await closure(primary)
            roots[request.name] = primary.name
            formulae.merge(resolved) { old, _ in old }
            continue
          }
        } catch MisoError.unsupported {}
        let names =
          request.name.contains("@") ? [] : (original["versioned_formulae"] as? [String] ?? [])
        var candidates: [Formula] = []
        for name in Array(Set(names)).sorted() {
          let candidateData = try await document(name)
          do {
            let candidate = try parse(candidateData, name: name, target: target)
            if request.version == nil || request.version == candidate.version {
              candidates.append(candidate)
            }
          } catch MisoError.unsupported { continue }
        }
        let ordered = try candidates.sorted(by: {
          if request.version != nil { return $0.name < $1.name }
          let left = try StableVersion($0.version)
          let right = try StableVersion($1.version)
          if left == right { return $0.name == request.name && $1.name != request.name }
          return left > right
        })
        var selected: Formula?
        for candidate in ordered {
          do {
            let resolved = try await closure(candidate)
            selected = candidate
            formulae.merge(resolved) { old, _ in old }
            break
          } catch MisoError.unsupported { continue }
        }
        guard let selected else {
          throw MisoError.unsupported(
            "no upstream-supported compatible version of \(request.name) matching \(request.version ?? "latest stable")"
          )
        }
        roots[request.name] = selected.name
      }
      for formula in formulae.values.sorted(by: { $0.name < $1.name }) {
        let source: Data
        if let metadata {
          source = try SafeFile.read(
            try GuestVolume(metadata).path(formula.name + ".rb"), limit: 8 << 20)
        } else {
          source = try await HTTPData.get(
            formula.sourceURL, maximumBytes: 8 << 20, cancellation: journal.cancellation)
        }
        guard SafeFile.hex(SHA256.hash(data: source)) == formula.sourceSHA256 else {
          throw MisoError.invalid("Formula source checksum mismatch: \(formula.name)")
        }
        try SafeFile.writeNew(source, to: directory.appendingPathComponent(formula.name + ".rb"))
      }
      let records = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        .map {
          try Artifacts.record(directory.appendingPathComponent($0), relativeTo: journal.output)
        }
      let result = Receipt(
        schemaVersion: 1, target: target, requests: requests, selectedRoots: roots,
        formulae: formulae, installOrder: try installOrder(formulae, roots: Array(roots.values)),
        metadata: records, payloadsIncluded: false, installationVerified: false,
        completeBaseResolution: false)
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("resolution.json"))
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

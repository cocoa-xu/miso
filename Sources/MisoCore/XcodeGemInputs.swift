import Foundation

public enum XcodeGemInputs {
  public struct Plan: Codable {
    let schemaVersion: Int
    let rubyVersion: String
    let rubygemsVersion: String
    let bundlerVersion: String
    let packages: [BasePackageInputs.Package]
  }

  struct Dependency: Codable, Equatable {
    let name: String
    let requirements: String
  }

  struct Metadata: Decodable {
    enum CodingKeys: String, CodingKey {
      case name, version, platform, sha, dependencies
      case gemURI = "gem_uri"
      case rubyVersion = "ruby_version"
      case rubygemsVersion = "rubygems_version"
    }
    struct Dependencies: Decodable { let runtime: [Dependency] }
    let name: String
    let version: String
    let platform: String
    let sha: String
    let gemURI: URL
    let rubyVersion: String?
    let rubygemsVersion: String?
    let dependencies: Dependencies

    func validate(name expected: String, candidate: PackageRegistryMetadata.GemVersion) throws {
      try XcodeGemInputs.validateName(name)
      guard name == expected, version == candidate.number, platform == "ruby",
        sha == candidate.sha, rubyVersion == candidate.rubyVersion,
        rubygemsVersion == candidate.rubygemsVersion,
        gemURI.absoluteString == "https://rubygems.org/gems/\(name)-\(version).gem",
        dependencies.runtime.count <= 128,
        Set(dependencies.runtime.map(\.name)).count == dependencies.runtime.count
      else { throw MisoError.invalid("Gem metadata differs from version index: \(expected)") }
      try SafeFile.validateSHA256(sha)
      for dependency in dependencies.runtime {
        try XcodeGemInputs.validateName(dependency.name)
        _ = try VersionRequirement(dependency.requirements, syntax: .gem)
      }
    }
  }

  static let roots = ["cocoapods", "fastlane", "xcpretty"]

  static func validateName(_ name: String) throws {
    guard name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z"#, options: .regularExpression) != nil
    else { throw MisoError.invalid("Invalid gem name") }
  }

  static func satisfies(_ version: String, constraints: [String]) throws -> Bool {
    try constraints.allSatisfy { try VersionRequirement($0, syntax: .gem).contains(version) }
  }

  static func compatible(
    _ candidate: PackageRegistryMetadata.GemVersion, ruby: String, rubygems: String
  ) throws -> Bool {
    try VersionRequirement(candidate.rubyVersion ?? ">= 0", syntax: .gem).contains(ruby)
      && VersionRequirement(candidate.rubygemsVersion ?? ">= 0", syntax: .gem).contains(rubygems)
  }

  static func metadataURL(name: String, version: String) throws -> URL {
    try validateName(name)
    _ = try StableVersion(version)
    return URL(
      string: "https://rubygems.org/api/v2/rubygems/\(name)/versions/\(version).json?platform=ruby")!
  }

  final class Resolver {
    enum Outcome {
      case resolved([String: Metadata])
      case conflict(Set<String>)
    }
    var registry: BasePackageRegistry
    let ruby: String
    let rubygems: String
    var indexes: [String: [PackageRegistryMetadata.GemVersion]] = [:]
    var metadata: [String: Metadata] = [:]
    var attempts = 0

    init(registry: BasePackageRegistry, ruby: String, rubygems: String) {
      self.registry = registry
      self.ruby = ruby
      self.rubygems = rubygems
    }

    func resolve(_ constraints: [String: [String]], selected: [String: Metadata] = [:]) async throws
      -> Outcome
    {
      try registry.cancellation.check()
      guard constraints.count <= 256, attempts < 4096 else {
        throw MisoError.unsupported("Gem dependency resolution exceeds bounded search")
      }
      func owners(_ dependency: String) -> Set<String> {
        Set(
          selected.values.filter { $0.dependencies.runtime.contains { $0.name == dependency } }.map(
            \.name))
      }
      for (name, value) in selected {
        if try !satisfies(value.version, constraints: constraints[name] ?? []) {
          return .conflict(owners(name).union([name]))
        }
      }
      guard let name = constraints.keys.sorted().first(where: { selected[$0] == nil }) else {
        return .resolved(selected)
      }
      if indexes[name] == nil {
        let bytes = try await registry.document(
          name + "-index", url: URL(string: "https://rubygems.org/api/v1/versions/\(name).json")!)
        indexes[name] = try PackageRegistryMetadata.gemVersions(bytes, requested: nil)
      }
      var conflicts = owners(name)
      for candidate in indexes[name]! {
        guard try compatible(candidate, ruby: ruby, rubygems: rubygems),
          try satisfies(candidate.number, constraints: constraints[name]!)
        else { continue }
        attempts += 1
        let key = name + "-" + candidate.number
        if metadata[key] == nil {
          let bytes = try await registry.document(
            key, url: metadataURL(name: name, version: candidate.number))
          let value = try JSONDecoder().decode(Metadata.self, from: bytes)
          try value.validate(name: name, candidate: candidate)
          metadata[key] = value
        }
        let value = metadata[key]!
        var next = constraints
        for dependency in value.dependencies.runtime {
          next[dependency.name, default: []].append(dependency.requirements)
        }
        var values = selected
        values[name] = value
        switch try await resolve(next, selected: values) {
        case .resolved(let result): return .resolved(result)
        case .conflict(let names):
          if !names.contains(name) { return .conflict(names) }
          conflicts.formUnion(names.subtracting([name]))
        }
      }
      return .conflict(conflicts)
    }
  }

  public static func prepare(
    rubyVersion: String, rubygemsVersion: String, bundlerVersion: String,
    output: URL, cache: URL? = nil, cancellation: CancellationToken? = nil
  ) async throws -> Plan {
    for version in [rubyVersion, rubygemsVersion, bundlerVersion] { _ = try StableVersion(version) }
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-gems", cancellation: cancellation)
    do {
      for directory in ["metadata", "payloads"] {
        try SafeFile.makeDirectory(output.appendingPathComponent(directory))
      }
      let resolver = try Resolver(
        registry: BasePackageRegistry(
          output: output, cache: cache.map(GuestVolume.init), cancellation: journal.cancellation),
        ruby: rubyVersion, rubygems: rubygemsVersion)
      var constraints = Dictionary(uniqueKeysWithValues: roots.map { ($0, [">= 0"]) })
      constraints["bundler"] = ["= " + bundlerVersion]
      guard case .resolved(let selected) = try await resolver.resolve(constraints) else {
        throw MisoError.unsupported("No compatible CocoaPods/fastlane/xcpretty dependency graph")
      }
      try journal.setMetadata("resolutionAttempts", value: resolver.attempts)
      var packages: [BasePackageInputs.Package] = []
      for name in selected.keys.sorted() {
        let value = selected[name]!
        let key = name + "-" + value.version
        try journal.setMetadata("downloading", value: key)
        let file = try await resolver.registry.payload(
          "payloads/" + key + ".gem", url: value.gemURI)
        let payload = try Artifacts.record(file, relativeTo: output)
        guard payload.sha256 == value.sha else {
          throw MisoError.invalid("Gem payload checksum differs from registry: \(name)")
        }
        packages.append(
          .init(
            name: name, version: value.version,
            metadata: try Artifacts.record(
              output.appendingPathComponent("metadata/" + key + ".json"), relativeTo: output),
            payload: payload))
      }
      let plan = Plan(
        schemaVersion: 1, rubyVersion: rubyVersion, rubygemsVersion: rubygemsVersion,
        bundlerVersion: bundlerVersion, packages: packages)
      try SafeFile.writeNew(JSON.encode(plan), to: output.appendingPathComponent("plan.json"))
      _ = try verify(output, cancellation: journal.cancellation)
      try journal.finish(plan)
      return plan
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  static func verify(_ input: URL, cancellation: CancellationToken?) throws -> Plan {
    let directory = try GuestVolume(input)
    let plan = try JSON.read(Plan.self, from: directory.path("plan.json"))
    for version in [plan.rubyVersion, plan.rubygemsVersion, plan.bundlerVersion] {
      _ = try StableVersion(version)
    }
    guard plan.schemaVersion == 1, (4...256).contains(plan.packages.count),
      Set(plan.packages.map(\.name)).count == plan.packages.count,
      Set(roots + ["bundler"]).isSubset(of: Set(plan.packages.map(\.name)))
    else { throw MisoError.invalid("Invalid Xcode gem plan") }
    let versions = Dictionary(uniqueKeysWithValues: plan.packages.map { ($0.name, $0.version) })
    guard versions["bundler"] == plan.bundlerVersion else {
      throw MisoError.invalid("Gem graph changes the selected Base Bundler")
    }
    var graph: [String: Metadata] = [:]
    for package in plan.packages {
      try validateName(package.name)
      _ = try StableVersion(package.version)
      let key = package.name + "-" + package.version
      guard package.metadata.path == "metadata/" + key + ".json",
        package.payload.path == "payloads/" + key + ".gem",
        package.metadata.bytes <= 8 << 20, package.payload.bytes <= 512 << 20
      else { throw MisoError.invalid("Unexpected gem record layout") }
      let metadata = try Artifacts.resolve(
        package.metadata, under: input, cancellation: cancellation)
      _ = try Artifacts.resolve(package.payload, under: input, cancellation: cancellation)
      let value = try JSON.read(Metadata.self, from: metadata)
      let candidates = try PackageRegistryMetadata.gemVersions(
        SafeFile.read(directory.path("metadata/" + package.name + "-index.json"), limit: 8 << 20),
        requested: package.version)
      guard candidates.count == 1,
        try compatible(candidates[0], ruby: plan.rubyVersion, rubygems: plan.rubygemsVersion),
        value.sha == package.payload.sha256
      else { throw MisoError.invalid("Gem plan is incompatible or differs from registry") }
      try value.validate(name: package.name, candidate: candidates[0])
      for dependency in value.dependencies.runtime {
        guard let version = versions[dependency.name],
          try satisfies(version, constraints: [dependency.requirements])
        else { throw MisoError.invalid("Unsatisfied gem dependency: \(dependency.name)") }
      }
      graph[package.name] = value
    }
    var reachable = Set<String>()
    var pending = roots + ["bundler"]
    while let name = pending.popLast() {
      if reachable.insert(name).inserted {
        pending += graph[name]!.dependencies.runtime.map(\.name)
      }
    }
    guard reachable == Set(graph.keys) else { throw MisoError.invalid("Unrequested gem payload") }
    return plan
  }
}

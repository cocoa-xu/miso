import Foundation

enum PackageRegistryMetadata {
  static let nativePNPM = "@pnpm/exe.darwin-arm64"

  struct NPM: Decodable {
    struct Distribution: Decodable {
      let tarball: URL
      let integrity: String?
    }
    let name: String
    let version: String
    let dist: Distribution
    let engines: [String: String]?
    let os: [String]?
    let cpu: [String]?
    let dependencies: [String: String]?
    let optionalDependencies: [String: String]?
    let deprecated: String?

    func validateManifest(_ data: Data) throws {
      struct Manifest: Decodable {
        let name: String
        let version: String
        let engines: [String: String]?
        let os: [String]?
        let cpu: [String]?
        let dependencies: [String: String]?
        let optionalDependencies: [String: String]?
      }
      let manifest = try JSONDecoder().decode(Manifest.self, from: data)
      guard manifest.name == name, manifest.version == version,
        manifest.engines ?? [:] == engines ?? [:], manifest.os == os, manifest.cpu == cpu,
        manifest.dependencies ?? [:] == dependencies ?? [:],
        manifest.optionalDependencies ?? [:] == optionalDependencies ?? [:]
      else { throw MisoError.invalid("npm archive manifest differs from registry: \(name)") }
    }

    func compatible(with runtimes: BasePackageInputs.Runtimes) throws -> Bool {
      for (values, target) in [(os, "darwin"), (cpu, "arm64")] {
        if let values,
          values.contains("!" + target)
            || !(values.allSatisfy { $0.hasPrefix("!") } || values.contains(target)
              || values.contains("any"))
        {
          return false
        }
      }
      for (name, version) in [("node", runtimes.node), ("npm", runtimes.npm)] {
        if let range = engines?[name],
          try !VersionRequirement(range, syntax: .npm).contains(version)
        {
          return false
        }
      }
      return true
    }

    func validate() throws {
      guard ["yarn", "pnpm", nativePNPM].contains(name), version.split(separator: ".").count == 3,
        dependencies?.isEmpty != false,
        dist.tarball.host == "registry.npmjs.org",
        dist.tarball.path == "/\(name)/-/\(name.split(separator: "/").last!)-\(version).tgz",
        let integrity = dist.integrity, integrity.hasPrefix("sha512-"),
        Data(base64Encoded: String(integrity.dropFirst(7)))?.count == 64
      else {
        throw MisoError.unsupported("Unsupported npm package payload or dependency layout: \(name)")
      }
      _ = try StableVersion(version)
      try HTTPFile.validate(dist.tarball, maximumBytes: 512 << 20)
      for (dependency, version) in optionalDependencies ?? [:] {
        guard name == "pnpm", dependency.hasPrefix("@pnpm/exe."),
          dependency.range(of: #"\A@pnpm/exe\.[a-z0-9-]+\z"#, options: .regularExpression) != nil
        else { throw MisoError.unsupported("Unknown npm optional dependency: \(dependency)") }
        _ = try StableVersion(version)
      }
    }
  }

  struct GemVersion: Decodable {
    enum CodingKeys: String, CodingKey {
      case number
      case platform
      case prerelease
      case rubyVersion = "ruby_version"
      case rubygemsVersion = "rubygems_version"
      case sha
    }
    let number: String
    let platform: String
    let prerelease: Bool
    let rubyVersion: String?
    let rubygemsVersion: String?
    let sha: String

    func compatible(ruby: String, rubygems: String) throws -> Bool {
      guard let rubyVersion, let rubygemsVersion else {
        throw MisoError.unsupported("Missing gem runtime compatibility metadata")
      }
      return try VersionRequirement(rubyVersion, syntax: .gem).contains(ruby)
        && VersionRequirement(rubygemsVersion, syntax: .gem).contains(rubygems)
    }
  }

  struct Gem: Decodable {
    enum CodingKeys: String, CodingKey {
      case name
      case version
      case platform
      case rubyVersion = "ruby_version"
      case rubygemsVersion = "rubygems_version"
      case sha
      case gemURI = "gem_uri"
      case dependencies
    }
    struct Dependencies: Decodable { let runtime: [JSONValue] }
    let name: String
    let version: String
    let platform: String
    let rubyVersion: String?
    let rubygemsVersion: String?
    let sha: String
    let gemURI: URL
    let dependencies: Dependencies

    func validate(_ candidate: GemVersion) throws {
      guard name == "bundler", version == candidate.number, platform == "ruby",
        sha == candidate.sha, rubyVersion == candidate.rubyVersion,
        rubygemsVersion == candidate.rubygemsVersion, dependencies.runtime.isEmpty,
        gemURI.host == "rubygems.org", gemURI.path == "/gems/bundler-\(version).gem"
      else { throw MisoError.invalid("Bundler metadata differs from the version index") }
      try SafeFile.validateSHA256(sha)
      try HTTPFile.validate(gemURI, maximumBytes: 512 << 20)
    }
  }

  static func npmVersions(_ data: Data, request: PackageRequest) throws -> [(NPM, Data)] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["name"] as? String == request.name,
      let versions = object["versions"] as? [String: [String: Any]], versions.count <= 10_000
    else { throw MisoError.invalid("Invalid npm version index") }
    let ceiling: StableVersion?
    if request.version == nil {
      guard let tags = object["dist-tags"] as? [String: String], let latest = tags["latest"],
        latest.split(separator: ".").count == 3, versions[latest] != nil,
        let stable = try? StableVersion(latest)
      else { throw MisoError.invalid("Missing or invalid npm stable channel") }
      ceiling = stable
    } else {
      ceiling = nil
    }
    var result: [(NPM, Data)] = []
    for (version, record) in versions {
      guard let stable = try? StableVersion(version), version.split(separator: ".").count == 3,
        ceiling == nil || stable <= ceiling!,
        request.version == nil || request.version == version
      else { continue }
      let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      let value = try JSONDecoder().decode(NPM.self, from: bytes)
      guard value.name == request.name, value.version == version else {
        throw MisoError.invalid("npm version index identity mismatch")
      }
      if request.version == nil, let warning = value.deprecated, !warning.isEmpty { continue }
      result.append((value, bytes))
    }
    return try result.sorted { try StableVersion($0.0.version) > StableVersion($1.0.version) }
  }

  static func gemVersions(_ data: Data, requested: String?) throws -> [GemVersion] {
    let versions = try JSONDecoder().decode([GemVersion].self, from: data)
    guard versions.count <= 10_000 else {
      throw MisoError.invalid("Gem version index exceeds limit")
    }
    let candidates = versions.filter {
      !$0.prerelease && $0.platform == "ruby" && (try? StableVersion($0.number)) != nil
        && (requested == nil || requested == $0.number)
    }
    guard Set(candidates.map(\.number)).count == candidates.count else {
      throw MisoError.invalid("Duplicate gem version index entries")
    }
    return try candidates.sorted { try StableVersion($0.number) > StableVersion($1.number) }
  }
}

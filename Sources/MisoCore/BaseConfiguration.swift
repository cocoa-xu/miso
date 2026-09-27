import Foundation

public struct PackageRequest: Codable, Equatable, Sendable {
  public var name: String
  public var version: String?

  public init(name: String, version: String? = nil) {
    self.name = name
    self.version = version
  }

  public func validate() throws {
    guard name.range(of: #"\A[a-z0-9][a-z0-9@+_.-]{0,100}\z"#, options: .regularExpression) != nil
    else { throw MisoError.invalid("Invalid package name") }
    if let version {
      guard
        version.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._+-]{0,79}\z"#, options: .regularExpression)
          != nil
      else {
        throw MisoError.invalid("Invalid upstream version identifier")
      }
    }
  }
}

struct StableVersion: Comparable, Equatable, Sendable {
  let components: [UInt32]

  init(_ value: String) throws {
    guard
      value.range(
        of: #"\A(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,3}\z"#,
        options: .regularExpression) != nil
    else {
      throw MisoError.invalid("Expected a stable numeric package version: \(value)")
    }
    let fields = value.split(separator: ".")
    let numbers = fields.compactMap { UInt32($0) }
    guard numbers.count == fields.count else { throw MisoError.invalid("Version is too large") }
    components = numbers + Array(repeating: 0, count: 4 - numbers.count)
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.components.lexicographicallyPrecedes(rhs.components)
  }
}

public struct BaseConfiguration: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var homebrewVersion: String?
  public var rubyVersion: String?
  public var additionalRubyVersions: [String] = ["2.7.8"]
  public var formulae: [PackageRequest] = [
    "awscli", "ca-certificates", "cmake", "curl", "gcc", "gh", "git-lfs",
    "gitlab-runner", "jq", "libyaml", "mise", "node@24", "rbenv", "ruby-build",
    "unzip", "wget", "yq", "zip",
  ].map { PackageRequest(name: $0) }
  public var npm: [PackageRequest] = ["yarn", "pnpm"].map { PackageRequest(name: $0) }
  public var thirdParty: [PackageRequest] = [
    "actions-runner", "buildkite-agent@3", "otel-cli", "tart-guest-agent",
    "git-credential-manager",
  ].map { PackageRequest(name: $0) }

  public init() {}

  public func validate() throws {
    guard schemaVersion == 1 else { throw MisoError.unsupported("Base configuration schema") }
    for version in [homebrewVersion, rubyVersion].compactMap({ $0 }) + additionalRubyVersions {
      _ = try StableVersion(version)
    }
    guard Set(additionalRubyVersions).count == additionalRubyVersions.count,
      rubyVersion.map({ !additionalRubyVersions.contains($0) }) ?? true
    else { throw MisoError.invalid("Duplicate Ruby versions") }
    for group in [formulae, npm, thirdParty] {
      guard group.count <= 256, Set(group.map(\.name)).count == group.count else {
        throw MisoError.invalid("Duplicate or excessive package requests")
      }
      for request in group { try request.validate() }
    }
  }
}

import Foundation

public struct BaseSourceConfiguration: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var repositories: [String: String] = [:]

  static let upstreams: Set<String> = [
    "Homebrew/brew", "Homebrew/homebrew-core", "openai/homebrew-tools",
    "buildkite/homebrew-buildkite", "equinix-labs/homebrew-otel-cli",
    "cirruslabs/homebrew-cli",
  ]

  public init() {}

  public func validate() throws {
    guard schemaVersion == 1, Set(repositories.keys).isSubset(of: Self.upstreams) else {
      throw MisoError.invalid("Unknown Homebrew source mapping")
    }
    for repository in repositories.values { _ = try GitRemote.repositoryURL(repository) }
  }

  func repository(_ upstream: String) -> String { repositories[upstream] ?? upstream }
}

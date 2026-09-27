import Foundation
import Testing

@testable import MisoCore

@Test func mobileGemMetadataBindsTheRubyPlatformAndIndexDigest() throws {
  let sha = String(repeating: "a", count: 64)
  let candidate = PackageRegistryMetadata.GemVersion(
    number: "4.1.3", platform: "ruby", prerelease: false,
    rubyVersion: ">= 2.6.0", rubygemsVersion: ">= 0", sha: sha)
  func metadata(platform: String = "ruby", digest: String? = nil) -> XcodeGemInputs.Metadata {
    .init(
      name: "bigdecimal", version: "4.1.3", platform: platform, sha: digest ?? sha,
      gemURI: URL(string: "https://rubygems.org/gems/bigdecimal-4.1.3.gem")!,
      rubyVersion: ">= 2.6.0", rubygemsVersion: ">= 0", dependencies: .init(runtime: []))
  }
  try metadata().validate(name: "bigdecimal", candidate: candidate)
  #expect(throws: MisoError.self) {
    try metadata(platform: "java").validate(name: "bigdecimal", candidate: candidate)
  }
  #expect(throws: MisoError.self) {
    try metadata(digest: String(repeating: "b", count: 64)).validate(
      name: "bigdecimal", candidate: candidate)
  }
  #expect(
    try XcodeGemInputs.metadataURL(name: "bigdecimal", version: "4.1.3").query == "platform=ruby")
  #expect(throws: MisoError.self) {
    try XcodeGemInputs.metadataURL(name: "../bigdecimal", version: "4.1.3")
  }
  let unconstrained = PackageRegistryMetadata.GemVersion(
    number: "1.2", platform: "ruby", prerelease: false,
    rubyVersion: nil, rubygemsVersion: nil, sha: sha)
  #expect(try XcodeGemInputs.compatible(unconstrained, ruby: "4.0.7", rubygems: "4.0.20"))
  #expect(try !XcodeGemInputs.compatible(candidate, ruby: "2.5.0", rubygems: "4.0.20"))
}

@Test func stableGemCandidatesRespectPrereleaseBounds() throws {
  for expression in ["< 2.a", "<= 2.a"] {
    #expect(try VersionRequirement(expression, syntax: .gem).contains("1.99"))
    #expect(try !VersionRequirement(expression, syntax: .gem).contains("2.0"))
  }
  for expression in ["> 2.a", ">= 2.a"] {
    #expect(try !VersionRequirement(expression, syntax: .gem).contains("1.99"))
    #expect(try VersionRequirement(expression, syntax: .gem).contains("2.0"))
  }
  #expect(try !VersionRequirement("= 2.a", syntax: .gem).contains("2.0"))
  #expect(try VersionRequirement("!= 2.a", syntax: .gem).contains("2.0"))
  #expect(try VersionRequirement("~> 2.3.0.a", syntax: .gem).contains("2.3.1"))
  #expect(try !VersionRequirement("~> 2.3.0.a", syntax: .gem).contains("2.4.0"))
}

@Test func gemResolutionBacktracksToTheConflictingDependency() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let resolver = XcodeGemInputs.Resolver(
    registry: BasePackageRegistry(
      output: temporary.url, cache: nil, cancellation: try CancellationToken()),
    ruby: "4.0.7", rubygems: "4.0.20")
  let sha = String(repeating: "a", count: 64)
  for (name, versions) in ["a": [2, 1], "b": Array((1...100).reversed()), "z": [1]] {
    resolver.indexes[name] = versions.map {
      PackageRegistryMetadata.GemVersion(
        number: String($0), platform: "ruby", prerelease: false,
        rubyVersion: ">= 0", rubygemsVersion: ">= 0", sha: sha)
    }
    for version in versions {
      resolver.metadata[name + "-" + String(version)] = .init(
        name: name, version: String(version), platform: "ruby", sha: sha,
        gemURI: URL(string: "https://rubygems.org/gems/\(name)-\(version).gem")!,
        rubyVersion: ">= 0", rubygemsVersion: ">= 0",
        dependencies: .init(runtime: name == "z" ? [.init(name: "a", requirements: "< 2")] : []))
    }
  }
  let result = try await resolver.resolve(["a": [">= 0"], "b": [">= 0"], "z": [">= 0"]])
  guard case .resolved(let selected) = result else {
    Issue.record("Compatible gem graph was rejected")
    return
  }
  #expect(selected["a"]?.version == "1")
  #expect(selected["b"]?.version == "100")
  #expect(resolver.attempts == 6)
  if case .resolved = try await resolver.resolve(["a": [">= 2"], "b": [">= 0"], "z": [">= 0"]]) {
    Issue.record("Conflicting gem graph was accepted")
  }
}

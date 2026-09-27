import Foundation
import Testing

@testable import MisoCore

private func definition(_ version: String = "4.0.7", legacy: Bool = false) -> Data {
  let series = version.split(separator: ".").prefix(2).joined(separator: ".")
  let ssl = legacy ? "1.1.1w" : "3.0.22"
  let sslURL =
    legacy
    ? "https://www.openssl.org/source/openssl-\(ssl).tar.gz"
    : "https://github.com/openssl/openssl/releases/download/openssl-\(ssl)/openssl-\(ssl).tar.gz"
  let bounds = legacy ? "1.0.1-1.x.x" : "1.1.1-3.x.x"
  return Data(
    """
    install_package "openssl-\(ssl)" "\(sslURL)#\(String(repeating: "a", count: 64))" openssl --if needs_openssl:\(bounds)
    install_package "ruby-\(version)" "https://cache.ruby-lang.org/pub/ruby/\(series)/ruby-\(version).tar.gz#\(String(repeating: "b", count: 64))" \(legacy ? "warn_eol " : "")enable_shared standard
    """.utf8)
}

@Test func rubyDefinitionsBindSourcesAndOpenSSLRequirements() throws {
  let current = try RubyBuildDefinition(definition(), version: "4.0.7")
  #expect(current.ruby.name == "ruby-4.0.7.tar.gz")
  #expect(current.ruby.sha256 == String(repeating: "b", count: 64))
  #expect(try current.acceptsOpenSSL("3.6.4"))
  #expect(try !current.acceptsOpenSSL("1.1.0"))
  #expect(try !current.acceptsOpenSSL("4.0.0"))
  let legacy = try RubyBuildDefinition(definition("2.7.8", legacy: true), version: "2.7.8")
  #expect(
    legacy.openssl.url.absoluteString
      == "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz"
  )
  #expect(try !legacy.acceptsOpenSSL("3.6.4"))
}

@Test func rubyResolutionSelectsOnlyStableDefinitionsAndHonorsExplicitVersions() throws {
  let names = ["4.0.7", "4.0.10", "4.1.0-preview1", "2.7.8", "jruby-10.0.0", "../9.0.0"]
  #expect(try RubyBuildDefinition.versions(names, requested: nil) == ["4.0.10", "4.0.7", "2.7.8"])
  #expect(try RubyBuildDefinition.versions(names, requested: "2.7.8") == ["2.7.8"])
  for requested in ["4.1.0", "4.1.0-preview1", "../4.0.7", "4"] {
    #expect(throws: (any Error).self) {
      try RubyBuildDefinition.versions(names, requested: requested)
    }
  }
  for names in [[], ["4.0.7", "4.0.7"], ["01.0.0"], ["jruby-1.0.0"]] {
    #expect(throws: (any Error).self) { try RubyBuildDefinition.versions(names, requested: nil) }
  }
}

@Test func rubyDefinitionParsingNeverExecutesOrIgnoresAdditionalSteps() throws {
  let good = String(decoding: definition(), as: UTF8.self)
  for changed in [
    good + "\nexit 0", good.replacingOccurrences(of: "install_package", with: "eval"),
    good.replacingOccurrences(of: "cache.ruby-lang.org", with: "evil.test"),
    good.replacingOccurrences(of: "https://", with: "http://"),
    good.replacingOccurrences(of: "enable_shared", with: "$(touch /tmp/bad)"),
    good.replacingOccurrences(of: "ruby-4.0.7.tar.gz", with: "ruby-4.0.8.tar.gz"),
    good.replacingOccurrences(of: "openssl/openssl", with: "evil/openssl"),
    good.replacingOccurrences(of: String(repeating: "b", count: 64), with: "bad"),
    good.replacingOccurrences(of: "1.1.1-3.x.x", with: "4.0.0-3.x.x"),
    good.replacingOccurrences(
      of: "enable_shared standard", with: "apply_patch enable_shared standard"),
  ] {
    #expect(throws: (any Error).self) {
      try RubyBuildDefinition(Data(changed.utf8), version: "4.0.7")
    }
  }
}

@Test func githubPayloadRedirectsStayWithinReleaseAssetService() {
  let source = URL(
    string:
      "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz")!
  let target = URL(
    string:
      "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc?signature=fixture"
  )!
  let gate = HTTPData.RedirectGate(source: source, policy: .githubRelease)
  for _ in 0..<3 { #expect(gate.accept(target)) }
  #expect(!gate.accept(target))
  #expect(!HTTPData.RedirectGate(source: source, policy: .reject).accept(target))
  for destination in [
    "http://release-assets.githubusercontent.com/github-production-release-asset/123/abc",
    "https://release-assets.githubusercontent.com.evil.test/github-production-release-asset/123/abc",
    "https://release-assets.githubusercontent.com:444/github-production-release-asset/123/abc",
    "https://user@release-assets.githubusercontent.com/github-production-release-asset/123/abc",
    "https://release-assets.githubusercontent.com/other/abc",
    "https://github.com/other/owner/releases/download/1.0.0/payload.tar.gz",
    "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc#fragment",
  ] {
    #expect(
      !HTTPData.RedirectPolicy.githubRelease.permits(from: source, to: URL(string: destination)!))
  }
  for origin in [
    "https://github.com.evil.test/a/b/releases/download/1.0.0/a.tar.gz",
    "https://github.com/a/b/raw/main/file", "https://user@github.com/a/b/releases/download/v1/file",
    "https://github.com/a/b/releases/download/v1/file?query", "https://example.test/file",
  ] {
    #expect(!HTTPData.RedirectPolicy.githubRelease.permits(from: URL(string: origin)!, to: target))
  }
}

import Foundation
import Testing

@testable import MisoCore

private func caskFixture(_ changes: [String: Any] = [:]) -> [String: Any] {
  [
    "token": "git-credential-manager", "version": "2.9.1", "disabled": false,
    "sha256": String(repeating: "a", count: 64),
    "url":
      "https://github.com/git-ecosystem/git-credential-manager/releases/download/v2.9.1/gcm-osx-arm64-2.9.1.pkg",
    "depends_on": [:], "tap_git_head": String(repeating: "b", count: 40),
    "ruby_source_path": "Casks/g/git-credential-manager.rb",
    "ruby_source_checksum": ["sha256": String(repeating: "c", count: 64)],
  ].merging(changes) { _, new in new }
}

private let gcmTarget = MacOSRelease(version: "15.6.1", build: "24G90")

@Test func credentialManagerCaskBindsVersionArchitectureAndRequirements() throws {
  let bytes = try JSONSerialization.data(withJSONObject: caskFixture())
  let cask = try BaseGCMResolution.Cask(bytes, target: gcmTarget, requested: "2.9.1")
  #expect(cask.version == "2.9.1")
  #expect(cask.recipeURL.path.contains(String(repeating: "b", count: 40)))
  for minimum in ["11", "15.0", "15.6.1"] {
    let value = caskFixture(["depends_on": ["macos": [">=": [minimum]]]])
    _ = try BaseGCMResolution.Cask(
      JSONSerialization.data(withJSONObject: value), target: gcmTarget, requested: nil)
  }
  for changes: [String: Any] in [
    ["disabled": true], ["token": "other"], ["version": "2.9.1-preview"],
    ["sha256": "no_check"], ["tap_git_head": "main"], ["ruby_source_path": "../file.rb"],
    ["url": "https://evil.test/package.pkg"],
    [
      "url":
        "https://github.com/git-ecosystem/git-credential-manager/releases/download/v2.9.1/gcm-osx-x64-2.9.1.pkg"
    ],
    ["depends_on": ["macos": [">=": ["26"]]]],
    ["depends_on": ["macos": ["==": ["15"]]]],
    ["depends_on": ["macos": [">=": ["15", "26"]]]],
    ["depends_on": ["formula": ["unreviewed"]]],
  ] {
    #expect(throws: (any Error).self) {
      try BaseGCMResolution.Cask(
        JSONSerialization.data(withJSONObject: caskFixture(changes)), target: gcmTarget,
        requested: nil)
    }
  }
  #expect(throws: (any Error).self) {
    try BaseGCMResolution.Cask(bytes, target: gcmTarget, requested: "2.8.0")
  }
}

@Test func credentialManagerCaskUsesOnlyTheRequestedArmTargetVariation() throws {
  let value = caskFixture([
    "variations": [
      "sequoia": ["url": "https://example.test/intel.pkg"],
      "arm64_sequoia": ["depends_on": ["macos": [">=": ["26"]]]],
    ]
  ])
  #expect(throws: (any Error).self) {
    try BaseGCMResolution.Cask(
      JSONSerialization.data(withJSONObject: value), target: gcmTarget, requested: nil)
  }
  _ = try BaseGCMResolution.Cask(
    JSONSerialization.data(withJSONObject: value), target: .init(version: "27.0", build: "26A428"),
    requested: nil)
}

@Test func credentialManagerResolutionReplaysWithoutSignatureOrInstallationClaims() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let cache = temporary.url.appendingPathComponent("cache")
  try SafeFile.makeDirectory(cache)
  let package = cache.appendingPathComponent("git-credential-manager.pkg")
  let recipe = cache.appendingPathComponent("recipe.rb")
  try SafeFile.writeNew(Data("inert package fixture".utf8), to: package)
  try SafeFile.writeNew(Data("inert cask fixture".utf8), to: recipe)
  let value = try caskFixture([
    "sha256": SafeFile.sha256(package), "ruby_source_checksum": ["sha256": SafeFile.sha256(recipe)],
  ])
  try SafeFile.writeNew(
    JSONSerialization.data(withJSONObject: value), to: cache.appendingPathComponent("cask.json"))
  let output = temporary.url.appendingPathComponent("resolved")
  let first = try await BaseGCMResolution.run(target: gcmTarget, output: output, cache: cache)
  #expect(!first.installationVerified && !first.signaturesVerified)
  let second = try await BaseGCMResolution.run(
    target: gcmTarget, output: temporary.url.appendingPathComponent("replayed"), cache: output)
  #expect(try JSON.encode(first) == JSON.encode(second))
  try SafeFile.replace(Data("tampered".utf8), at: package)
  await #expect(throws: (any Error).self) {
    try await BaseGCMResolution.run(
      target: gcmTarget, output: temporary.url.appendingPathComponent("invalid"), cache: cache)
  }
}

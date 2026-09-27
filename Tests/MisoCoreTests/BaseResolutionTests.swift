import Foundation
import Testing

@testable import MisoCore

private let formulaSource = Data("class Example < Formula; end\n".utf8)

private func formulaMetadata(
  name: String = "example", version: String = "2.1.0", tag: String = "arm64_sequoia",
  dependencies: [String] = [], digest: String = String(repeating: "a", count: 64),
  changes: [String: Any] = [:]
) throws -> Data {
  let path = name.replacingOccurrences(of: "@", with: "/")
  let value: [String: Any] = [
    "name": name, "versions": ["stable": version], "revision": 0,
    "dependencies": dependencies, "requirements": [], "disabled": false, "keg_only": false,
    "ruby_source_path": "Formula/e/\(name).rb", "tap_git_head": String(repeating: "b", count: 40),
    "ruby_source_checksum": ["sha256": SafeFile.sha256(formulaSource)],
    "post_install_defined": false, "uses_from_macos": [], "uses_from_macos_bounds": [],
    "bottle": [
      "stable": [
        "rebuild": 0,
        "files": [
          tag: [
            "cellar": ":any", "sha256": digest,
            "url": "https://ghcr.io/v2/homebrew/core/\(path)/blobs/sha256:\(digest)",
          ]
        ],
      ]
    ],
  ]
  return try JSONSerialization.data(
    withJSONObject: value.merging(changes) { _, new in new }, options: .sortedKeys)
}

@Test func bottleDownloadReplaysValidatedInputsAndNeverFallsBackFromCache() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let root = temporary.url
  let metadata = root.appendingPathComponent("metadata")
  let cache = root.appendingPathComponent("cache")
  try SafeFile.makeDirectory(metadata)
  try SafeFile.makeDirectory(cache)
  let archive =
    tarEntry(path: "example/2.1.0/.brew/example.rb", content: formulaSource)
    + Data(repeating: 0, count: 1024)
  let digest = SafeFile.sha256(archive)
  try SafeFile.writeNew(
    formulaMetadata(digest: digest), to: metadata.appendingPathComponent("example.json"))
  try SafeFile.writeNew(formulaSource, to: metadata.appendingPathComponent("example.rb"))
  let resolution = root.appendingPathComponent("resolution")
  _ = try await HomebrewResolution.run(
    requests: [.init(name: "example")], target: RestoreProfile.supported[0].release,
    output: resolution, metadata: metadata)
  let index = try JSONSerialization.data(withJSONObject: [
    "schemaVersion": 2,
    "manifests": [
      [
        "annotations": [
          "org.opencontainers.image.ref.name": "2.1.0.arm64_sequoia",
          "sh.brew.bottle.digest": digest, "sh.brew.bottle.size": String(archive.count),
          "sh.brew.tab": "{\"runtime_dependencies\":[]}",
        ]
      ]
    ],
  ])
  try SafeFile.writeNew(index, to: cache.appendingPathComponent("example.tar.index.json"))
  try SafeFile.writeNew(archive, to: cache.appendingPathComponent("example.tar.gz"))
  let replay = try await HomebrewBottleDownload.run(
    resolution: resolution, output: root.appendingPathComponent("replay"), cache: cache)
  #expect(replay.payloads.count == 1 && replay.payloads[0].archive.sha256 == digest)
  let reused = try await HomebrewBottleDownload.run(
    resolution: resolution, output: root.appendingPathComponent("reused"),
    reuse: root.appendingPathComponent("replay"))
  #expect(reused.payloads.map(\.archive) == replay.payloads.map(\.archive))
  await #expect(throws: MisoError.self) {
    try await HomebrewBottleDownload.run(
      resolution: resolution, output: root.appendingPathComponent("ambiguous"), cache: cache,
      reuse: root.appendingPathComponent("replay"))
  }
  var previous = try JSON.read(
    ExecutionJournal.Record.self, from: root.appendingPathComponent("replay/journal.json"))
  previous.status = .running
  try SafeFile.replace(
    JSON.encode(previous), at: root.appendingPathComponent("replay/journal.json"))
  await #expect(throws: MisoError.self) {
    try await HomebrewBottleDownload.run(
      resolution: resolution, output: root.appendingPathComponent("running"),
      reuse: root.appendingPathComponent("replay"))
  }
  previous.status = .failed
  previous.metadata["resolutionSHA256"] = .string(String(repeating: "f", count: 64))
  try SafeFile.replace(
    JSON.encode(previous), at: root.appendingPathComponent("replay/journal.json"))
  await #expect(throws: MisoError.self) {
    try await HomebrewBottleDownload.run(
      resolution: resolution, output: root.appendingPathComponent("different"),
      reuse: root.appendingPathComponent("replay"))
  }
  try SafeFile.replace(Data("corrupt".utf8), at: cache.appendingPathComponent("example.tar.gz"))
  await #expect(throws: (any Error).self) {
    try await HomebrewBottleDownload.run(
      resolution: resolution, output: root.appendingPathComponent("corrupt"), cache: cache)
  }
  let empty = root.appendingPathComponent("empty")
  try SafeFile.makeDirectory(empty)
  await #expect(throws: (any Error).self) {
    try await HomebrewBottleDownload.run(
      resolution: resolution, output: root.appendingPathComponent("missing"), cache: empty)
  }
  #expect(throws: MisoError.self) {
    try HomebrewBottleInputs.resolve(resolution, names: ["example", "example"], cancellation: nil)
  }
}

@Test func baseDefaultsKeepVersionsDynamicAndAcceptExplicitVersions() throws {
  var configuration = BaseConfiguration()
  try configuration.validate()
  #expect(configuration.homebrewVersion == nil && configuration.rubyVersion == nil)
  #expect(configuration.formulae.allSatisfy { $0.version == nil })
  #expect(configuration.npm.allSatisfy { $0.version == nil })
  #expect(configuration.thirdParty.allSatisfy { $0.version == nil })
  configuration.homebrewVersion = "7.1.3"
  configuration.rubyVersion = "4.1.2"
  configuration.formulae = [.init(name: "node@24", version: "24.12.1")]
  try configuration.validate()
  #expect(try StableVersion("9.10.0") > StableVersion("9.9.9"))
  try PackageRequest(name: "ca-certificates", version: "2026-09-25").validate()
  for invalid in ["", "1.2-rc1", "1.2;id", "1.02", "99999999999999999999"] {
    #expect(throws: (any Error).self) { try StableVersion(invalid) }
  }
  configuration.formulae.append(configuration.formulae[0])
  #expect(throws: (any Error).self) { try configuration.validate() }
}

@Test func preparationPinsOneCoherentCoreSnapshot() throws {
  let target = RestoreProfile.supported[0].release
  let first = try HomebrewResolution.parse(formulaMetadata(), name: "example", target: target)
  let second = try HomebrewResolution.parse(
    formulaMetadata(name: "other", changes: ["tap_git_head": String(repeating: "c", count: 40)]),
    name: "other", target: target)
  func receipt(_ formulae: [String: HomebrewResolution.Formula]) -> HomebrewResolution.Receipt {
    .init(
      schemaVersion: 1, target: target, requests: [], selectedRoots: [:], formulae: formulae,
      installOrder: [], metadata: [], payloadsIncluded: false, installationVerified: false,
      completeBaseResolution: false)
  }
  #expect(try BaseSoftwarePreparation.coreRevision(receipt(["example": first])) == first.tapCommit)
  #expect(throws: MisoError.self) {
    try BaseSoftwarePreparation.coreRevision(receipt(["example": first, "other": second]))
  }
  #expect(throws: MisoError.self) { try BaseSoftwarePreparation.coreRevision(receipt([:])) }
}

@Test func formulaCompatibilityUsesTargetNotHostAndAppliesVariations() throws {
  let target = RestoreProfile.supported[0].release
  let data = try formulaMetadata(changes: [
    "variations": ["arm64_sequoia": ["dependencies": ["library"]]]
  ])
  let formula = try HomebrewResolution.parse(data, name: "example", target: target)
  #expect(formula.dependencies == ["library"])
  #expect(formula.bottle.tag == "arm64_sequoia")
  #expect(throws: (any Error).self) {
    try HomebrewResolution.parse(data, name: "example", target: RestoreProfile.supported[1].release)
  }
  for requirements: [[String: Any]] in [
    [["name": "macos", "version": "26"]], [["name": "arch", "version": "x86_64"]],
    [["name": "unknown-runtime"]],
  ] {
    #expect(throws: (any Error).self) {
      try HomebrewResolution.parse(
        formulaMetadata(changes: ["requirements": requirements]), name: "example", target: target)
    }
  }
  let requirements = [["name": "xcode", "contexts": ["build"], "version": "27"]]
  _ = try HomebrewResolution.parse(
    formulaMetadata(changes: ["requirements": requirements]), name: "example", target: target)
}

@Test func formulaMacOSDependenciesAndBottleFallbackAreExplicit() throws {
  let value = try formulaMetadata(
    tag: "all",
    changes: [
      "uses_from_macos": ["zlib", "new-library", ["compiler": "build"]] as [Any],
      "uses_from_macos_bounds": [[:], ["since": "tahoe"], [:]],
    ])
  let formula = try HomebrewResolution.parse(
    value, name: "example", target: RestoreProfile.supported[0].release)
  #expect(formula.bottle.tag == "all")
  #expect(formula.systemDependencies == ["zlib"])
  #expect(formula.dependencies == ["new-library"])
  for changes: [String: Any] in [
    ["disabled": true], ["name": "wrong"], ["ruby_source_path": "../bad.rb"],
    ["uses_from_macos": ["zlib"], "uses_from_macos_bounds": []],
    ["uses_from_macos": ["zlib"], "uses_from_macos_bounds": [["since": "unknown"]]],
  ] {
    #expect(throws: (any Error).self) {
      try HomebrewResolution.parse(
        formulaMetadata(changes: changes), name: "example",
        target: RestoreProfile.supported[0].release)
    }
  }
}

@Test func formulaDependencyGraphRejectsCyclesAndMissingNodes() throws {
  let target = RestoreProfile.supported[0].release
  let root = try HomebrewResolution.parse(
    formulaMetadata(dependencies: ["library"]), name: "example", target: target)
  let library = try HomebrewResolution.parse(
    formulaMetadata(name: "library"), name: "library", target: target)
  #expect(
    try HomebrewResolution.installOrder(["example": root, "library": library], roots: ["example"])
      == ["library", "example"])
  #expect(throws: (any Error).self) {
    try HomebrewResolution.installOrder(["example": root], roots: ["example"])
  }
  let cyclic = try HomebrewResolution.parse(
    formulaMetadata(name: "library", dependencies: ["example"]), name: "library", target: target)
  #expect(throws: (any Error).self) {
    try HomebrewResolution.installOrder(["example": root, "library": cyclic], roots: ["example"])
  }
}

@Test func formulaResolutionSelectsCompatibleUpstreamVersionAndReplaysOffline() async throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let metadata = directory.url.appendingPathComponent("metadata")
  try SafeFile.makeDirectory(metadata)
  let newer = try formulaMetadata(
    version: "3.0.0", tag: "arm64_tahoe", changes: ["versioned_formulae": ["example@2"]])
  try SafeFile.writeNew(newer, to: metadata.appendingPathComponent("example.json"))
  try SafeFile.writeNew(
    formulaMetadata(name: "example@2", dependencies: ["library"]),
    to: metadata.appendingPathComponent("example@2.json"))
  try SafeFile.writeNew(
    formulaMetadata(name: "library"), to: metadata.appendingPathComponent("library.json"))
  for name in ["example@2", "library"] {
    try SafeFile.writeNew(formulaSource, to: metadata.appendingPathComponent(name + ".rb"))
  }
  let target = RestoreProfile.supported[0].release
  let result = try await HomebrewResolution.run(
    requests: [.init(name: "example")], target: target,
    output: directory.url.appendingPathComponent("resolved"), metadata: metadata)
  #expect(result.selectedRoots == ["example": "example@2"])
  #expect(result.installOrder == ["library", "example@2"])
  #expect(
    !result.installationVerified && !result.completeBaseResolution && !result.payloadsIncluded)
  let explicit = try await HomebrewResolution.run(
    requests: [.init(name: "example", version: "2.1.0")], target: target,
    output: directory.url.appendingPathComponent("explicit"), metadata: metadata)
  #expect(explicit.formulae == result.formulae)
  await #expect(throws: (any Error).self) {
    try await HomebrewResolution.run(
      requests: [.init(name: "example", version: "1.0.0")], target: target,
      output: directory.url.appendingPathComponent("missing"), metadata: metadata)
  }
  try SafeFile.replace(Data("changed".utf8), at: metadata.appendingPathComponent("library.rb"))
  await #expect(throws: (any Error).self) {
    try await HomebrewResolution.run(
      requests: [.init(name: "example")], target: target,
      output: directory.url.appendingPathComponent("tampered"), metadata: metadata)
  }
}

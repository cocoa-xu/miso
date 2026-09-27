import Foundation
import Testing

@testable import MisoCore

private let runnerTarget = MacOSRelease(version: "15.6.1", build: "24G90")
private let runnerName = "actions-runner-osx-arm64-2.340.0.tar.gz"

private func runnerMetadata(_ assetChanges: [String: Any] = [:]) -> [String: Any] {
  let asset: [String: Any] = [
    "name": runnerName, "size": 1024, "digest": "sha256:" + String(repeating: "a", count: 64),
    "browser_download_url": "https://github.com/actions/runner/releases/download/v2.340.0/"
      + runnerName,
  ].merging(assetChanges) { _, new in new }
  return ["tag_name": "v2.340.0", "draft": false, "prerelease": false, "assets": [asset]]
}

private func runnerExecutable(minimum: UInt32 = 0x000F_0000) -> Data {
  var data = Data(repeating: 0, count: 56)
  for (offset, value): (Int, UInt32) in [
    (0, 0xFEED_FACF), (4, 0x0100_000C), (12, 2), (16, 1), (20, 24),
    (32, 0x32), (36, 24), (40, 1), (44, minimum),
  ] {
    var number = value.littleEndian
    withUnsafeBytes(of: &number) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
  }
  return data
}

private func runnerFixture(_ root: URL, minimum: UInt32 = 0x000F_0000) throws {
  try SafeFile.makeDirectory(root)
  var archive = Data()
  archive += tarEntry(path: "run.sh", content: Data("#!/bin/sh\nexit 0\n".utf8))
  for path in ["bin/Runner.Listener", "bin/Runner.Worker", "externals/node24/bin/node"] {
    archive += tarEntry(path: path, content: runnerExecutable(minimum: minimum))
  }
  archive += Data(repeating: 0, count: 1024)
  let payload = root.appendingPathComponent(runnerName)
  try SafeFile.writeNew(archive, to: payload)
  let metadata = try runnerMetadata([
    "size": archive.count, "digest": "sha256:" + SafeFile.sha256(payload),
  ])
  try SafeFile.writeNew(
    JSONSerialization.data(withJSONObject: metadata),
    to: root.appendingPathComponent("release.json"))
}

@Test func runnerReleaseBindsStableVersionArchitectureChecksumAndSize() throws {
  let bytes = try JSONSerialization.data(withJSONObject: runnerMetadata())
  let release = try BaseRunnerResolution.Release(bytes, requested: "2.340.0")
  #expect(release.version == "2.340.0" && release.name == runnerName)
  for changes: [String: Any] in [
    ["name": "actions-runner-osx-x64-2.340.0.tar.gz"], ["digest": "sha256:invalid"],
    ["browser_download_url": "https://example.test/" + runnerName],
    ["size": 0], ["size": -1], ["size": true], ["size": 1.5], ["size": 513 << 20],
  ] {
    #expect(throws: (any Error).self) {
      try BaseRunnerResolution.Release(
        JSONSerialization.data(withJSONObject: runnerMetadata(changes)), requested: nil)
    }
  }
  for changes: [String: Any] in [
    ["draft": true], ["prerelease": true], ["tag_name": "v2.340.0-rc1"],
    ["assets": Array(repeating: (runnerMetadata()["assets"] as! [[String: Any]])[0], count: 2)],
  ] {
    #expect(throws: (any Error).self) {
      try BaseRunnerResolution.Release(
        JSONSerialization.data(withJSONObject: runnerMetadata().merging(changes) { _, new in new }),
        requested: nil)
    }
  }
  #expect(throws: (any Error).self) {
    try BaseRunnerResolution.Release(bytes, requested: "2.339.0")
  }
}

@Test func runnerResolutionReplaysAndRejectsTamperingWithoutInstallationClaims() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let cache = temporary.url.appendingPathComponent("cache")
  try runnerFixture(cache)
  let output = temporary.url.appendingPathComponent("resolved")
  let first = try await BaseRunnerResolution.run(target: runnerTarget, output: output, cache: cache)
  #expect(first.executableMinimumMacOS.count == 3)
  #expect(!first.installationVerified && !first.runtimeVerified)
  let replay = try await BaseRunnerResolution.run(
    target: runnerTarget, output: temporary.url.appendingPathComponent("replay"), cache: output)
  #expect(try JSON.encode(first) == JSON.encode(replay))
  try SafeFile.replace(Data("modified".utf8), at: cache.appendingPathComponent(runnerName))
  await #expect(throws: (any Error).self) {
    try await BaseRunnerResolution.run(
      target: runnerTarget, output: temporary.url.appendingPathComponent("invalid"), cache: cache)
  }
}

@Test func runnerResolutionRejectsNewerDeploymentTargetsAndMissingRuntimes() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let cache = temporary.url.appendingPathComponent("cache")
  try runnerFixture(cache, minimum: 0x001A_0201)
  await #expect(throws: (any Error).self) {
    try await BaseRunnerResolution.run(
      target: runnerTarget, output: temporary.url.appendingPathComponent("too-new"), cache: cache)
  }
  _ = try await BaseRunnerResolution.run(
    target: .init(version: "26.6.2", build: "25G83"),
    output: temporary.url.appendingPathComponent("compatible"), cache: cache)
  let missing = temporary.url.appendingPathComponent("missing.tar")
  try SafeFile.writeNew(
    tarEntry(path: "bin/Runner.Listener", content: runnerExecutable())
      + Data(repeating: 0, count: 1024),
    to: missing)
  #expect(throws: (any Error).self) {
    try BaseRunnerResolution.inspect(missing, target: runnerTarget, cancellation: nil)
  }
}

import Foundation
import Testing

@testable import MisoCore

private struct PackageRegistryFixture {
  let root: URL

  init(_ root: URL) throws {
    self.root = root
    for directory in ["metadata", "payloads"] {
      try SafeFile.makeDirectory(root.appendingPathComponent(directory))
    }
    var gems: [[String: Any]] = []
    for (version, ruby, rubygems) in [("4.0.22", ">=3.2", ">=3.4.1"), ("2.4.22", ">=2.6", ">=3.0")]
    {
      let payload = root.appendingPathComponent("payloads/bundler-\(version).gem")
      try SafeFile.writeNew(Data("inert resolver fixture \(version)".utf8), to: payload)
      let sha = try SafeFile.sha256(payload)
      gems.append([
        "number": version, "platform": "ruby", "prerelease": false,
        "ruby_version": ruby, "rubygems_version": rubygems, "sha": sha,
      ])
      try document(
        "bundler-" + version,
        [
          "name": "bundler", "version": version, "platform": "ruby", "sha": sha,
          "ruby_version": ruby, "rubygems_version": rubygems,
          "gem_uri": "https://rubygems.org/gems/bundler-\(version).gem",
          "dependencies": ["runtime": []],
        ])
    }
    try document("bundler-index", gems)
    try catalog(
      "yarn", latest: "1.2.0",
      versions: [
        npm("yarn", "1.2.0", fields: ["engines": ["node": ">=20"]]),
        npm("yarn", "1.1.0", fields: ["engines": ["node": ">=16"]]),
        npm("yarn", "2.0.0"),
      ])
    try catalog(
      "pnpm", latest: "2.0.0",
      versions: [
        npm(
          "pnpm", "2.0.0",
          fields: ["optionalDependencies": [PackageRegistryMetadata.nativePNPM: "3.0.0"]]),
        npm(
          "pnpm", "1.9.0",
          fields: ["optionalDependencies": [PackageRegistryMetadata.nativePNPM: "3.0.0"]]),
        npm(
          "pnpm", "1.8.0",
          fields: ["optionalDependencies": [PackageRegistryMetadata.nativePNPM: "2.0.0"]]),
      ])
    try catalog(
      PackageRegistryMetadata.nativePNPM, latest: "3.0.0",
      versions: [
        npm(PackageRegistryMetadata.nativePNPM, "3.0.0", deployment: 27),
        npm(PackageRegistryMetadata.nativePNPM, "2.0.0", deployment: 11),
      ])
  }

  func document(_ key: String, _ value: Any) throws {
    try SafeFile.writeNew(
      registryBytes(value), to: root.appendingPathComponent("metadata/\(key).json"))
  }

  func catalog(_ name: String, latest: String, versions: [[String: Any]]) throws {
    try document(
      "npm-" + name.replacingOccurrences(of: "/", with: "_"),
      [
        "name": name, "dist-tags": ["latest": latest],
        "versions": Dictionary(
          uniqueKeysWithValues: versions.map { ($0["version"] as! String, $0) }),
      ])
  }

  func npm(
    _ name: String, _ version: String, fields: [String: Any] = [:], deployment: UInt32? = nil
  ) throws -> [String: Any] {
    var value = registryPackage(
      name: name, version: version, changes: ["engines": [:]].merging(fields) { _, new in new })
    var archive = try tarEntry(path: "package/package.json", content: registryBytes(value))
    if let deployment {
      var executable = Data(repeating: 0, count: 56)
      for (offset, field): (Int, UInt32) in [
        (0, 0xFEED_FACF), (4, 0x0100_000C), (12, 2), (16, 1), (20, 24),
        (32, 0x32), (36, 24), (40, 1), (44, deployment << 16),
      ] {
        var number = field.littleEndian
        withUnsafeBytes(of: &number) { executable.replaceSubrange(offset..<(offset + 4), with: $0) }
      }
      archive += tarEntry(path: "package/pnpm", content: executable)
    }
    archive += Data(repeating: 0, count: 1024)
    let key = name.replacingOccurrences(of: "/", with: "_") + "-" + version
    let payload = root.appendingPathComponent("payloads/\(key).tgz")
    try SafeFile.writeNew(archive, to: payload)
    var distribution = value["dist"] as! [String: Any]
    distribution["integrity"] = try BasePackageInputs.integrity(payload)
    value["dist"] = distribution
    return value
  }

  func resolve(output: URL, requests: [PackageRequest]? = nil, bundler: String? = nil) async throws
    -> BasePackageResolution.Receipt
  {
    try await BasePackageResolution.run(
      requests: requests ?? [.init(name: "yarn"), .init(name: "pnpm")], bundlerVersion: bundler,
      target: .init(version: "15.6.1", build: "24G90"), rubyVersion: "2.7.8",
      nodeFormula: "node@18",
      runtimes: .init(node: "18.0.0", npm: "10.0.0", rubygems: "3.1.6"),
      output: output, cache: root)
  }
}

@Test func packageResolutionReplaysCompatibilityFallbackAndRejectedNativeInputs() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let fixture = try PackageRegistryFixture(temporary.url)
  let first = temporary.url.appendingPathComponent("first")
  let receipt = try await fixture.resolve(output: first)
  #expect(receipt.plan.bundler.version == "2.4.22")
  #expect(receipt.plan.npm.map(\.version) == ["1.1.0", "2.0.0", "1.8.0"])
  #expect(receipt.rejected.filter { $0.reason == "native-minimum-macos" }.count == 2)
  #expect(receipt.payloads.count == 5)
  #expect(!receipt.installationVerified && !receipt.completeBaseResolution)
  let replay = temporary.url.appendingPathComponent("replayed")
  let repeated = try await BasePackageResolution.run(
    requests: receipt.requests, target: receipt.target, rubyVersion: receipt.plan.rubyVersion,
    nodeFormula: receipt.plan.nodeFormula, runtimes: try #require(receipt.plan.runtimes),
    output: replay, cache: first)
  #expect(try JSON.encode(receipt) == JSON.encode(repeated))
}

@Test func explicitPackageRequestsNeverSilentlyFallback() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let fixture = try PackageRegistryFixture(temporary.url)
  for (index, request) in [
    PackageRequest(name: "yarn", version: "1.2.0"),
    PackageRequest(name: "pnpm", version: "2.0.0"),
    PackageRequest(name: "yarn", version: "9.0.0"),
  ].enumerated() {
    await #expect(throws: (any Error).self) {
      try await fixture.resolve(
        output: temporary.url.appendingPathComponent("invalid-\(index)"), requests: [request])
    }
  }
  await #expect(throws: (any Error).self) {
    try await fixture.resolve(
      output: temporary.url.appendingPathComponent("bundler-incompatible"), bundler: "4.0.22")
  }
  let explicit = try await fixture.resolve(
    output: temporary.url.appendingPathComponent("explicit"),
    requests: [.init(name: "yarn", version: "2.0.0")])
  #expect(explicit.plan.npm.map(\.version) == ["2.0.0"])
}

@Test func packageResolutionRejectsCorruptOrMissingCachedInputs() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let fixture = try PackageRegistryFixture(temporary.url)
  let payload = temporary.url.appendingPathComponent("payloads/yarn-1.1.0.tgz")
  try SafeFile.replace(Data("corrupted fixture".utf8), at: payload)
  await #expect(throws: (any Error).self) {
    try await fixture.resolve(output: temporary.url.appendingPathComponent("corrupt"))
  }
  try FileManager.default.removeItem(at: payload)
  await #expect(throws: (any Error).self) {
    try await fixture.resolve(output: temporary.url.appendingPathComponent("missing"))
  }
}

@Test func packageResolutionSkipsMissingNativeDependencies() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let fixture = try PackageRegistryFixture(temporary.url)
  let index = temporary.url.appendingPathComponent("metadata/npm-@pnpm_exe.darwin-arm64.json")
  var metadata = try #require(
    JSONSerialization.jsonObject(with: SafeFile.read(index, limit: 1 << 20)) as? [String: Any])
  var versions = try #require(metadata["versions"] as? [String: Any])
  versions.removeValue(forKey: "3.0.0")
  metadata["versions"] = versions
  try SafeFile.replace(registryBytes(metadata), at: index)
  let receipt = try await fixture.resolve(
    output: temporary.url.appendingPathComponent("missing-native"))
  #expect(receipt.plan.npm.last?.version == "1.8.0")
  #expect(
    receipt.rejected.filter { $0.reason == "missing-or-incompatible-arm64-component" }.count == 2)
}

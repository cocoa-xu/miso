import Foundation
import Testing

@testable import MisoCore

func registryPackage(
  name: String = "pnpm", version: String = "2.0.0", changes: [String: Any] = [:]
) -> [String: Any] {
  [
    "name": name, "version": version, "engines": ["node": ">=20", "npm": ">=10"],
    "dist": [
      "tarball":
        "https://registry.npmjs.org/\(name)/-/\(name.split(separator: "/").last!)-\(version).tgz",
      "integrity": "sha512-" + Data(repeating: 1, count: 64).base64EncodedString(),
    ],
  ].merging(changes) { _, new in new }
}

func registryBytes(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
}

@Test func npmResolutionOrdersStableVersionsAndHonorsExplicitSelection() throws {
  let data = try registryBytes([
    "name": "pnpm", "dist-tags": ["latest": "2.0.0"],
    "versions": [
      "1.0.0": registryPackage(version: "1.0.0"),
      "2.0.0": registryPackage(),
      "3.0.0-beta.1": registryPackage(version: "3.0.0-beta.1"),
      "3.0.0": registryPackage(version: "3.0.0", changes: ["deprecated": "unavailable"]),
      "4.0.0": registryPackage(version: "4.0.0"),
    ],
  ])
  let candidates = try PackageRegistryMetadata.npmVersions(data, request: .init(name: "pnpm"))
  #expect(candidates.map { $0.0.version } == ["2.0.0", "1.0.0"])
  #expect(
    try PackageRegistryMetadata.npmVersions(data, request: .init(name: "pnpm", version: "1.0.0"))
      .count == 1)
  #expect(
    try PackageRegistryMetadata.npmVersions(data, request: .init(name: "pnpm", version: "9.0.0"))
      .isEmpty)
  #expect(
    try PackageRegistryMetadata.npmVersions(data, request: .init(name: "pnpm", version: "3.0.0"))
      .count == 1)
  #expect(
    try PackageRegistryMetadata.npmVersions(data, request: .init(name: "pnpm", version: "4.0.0"))
      .count == 1)
  #expect(throws: (any Error).self) {
    try PackageRegistryMetadata.npmVersions(data, request: .init(name: "yarn"))
  }
}

@Test func npmDefaultsStayWithinTheUpstreamStableChannel() throws {
  for latest in ["1.0.0", "9.0.0", "2.0.0-beta.1", "invalid"] {
    let data = try registryBytes([
      "name": "yarn", "dist-tags": ["latest": latest],
      "versions": [
        "1.0.0": registryPackage(name: "yarn", version: "1.0.0"),
        "2.0.0": registryPackage(name: "yarn", version: "2.0.0"),
        "2.0.0-beta.1": registryPackage(name: "yarn", version: "2.0.0-beta.1"),
      ],
    ])
    if latest == "1.0.0" {
      let candidates = try PackageRegistryMetadata.npmVersions(data, request: .init(name: "yarn"))
      #expect(candidates.map { $0.0.version } == ["1.0.0"])
    } else {
      #expect(throws: (any Error).self) {
        try PackageRegistryMetadata.npmVersions(data, request: .init(name: "yarn"))
      }
    }
    #expect(
      try PackageRegistryMetadata.npmVersions(data, request: .init(name: "yarn", version: "2.0.0"))
        .count == 1)
  }
}

@Test func npmArchiveRequirementsMustMatchTheResolvedMetadata() throws {
  let value = registryPackage()
  let package = try JSONDecoder().decode(
    PackageRegistryMetadata.NPM.self, from: registryBytes(value))
  try package.validateManifest(registryBytes(value))
  try package.validateManifest(
    registryBytes(value.merging(["dependencies": [:]]) { _, new in new }))
  for changes: [String: Any] in [
    ["version": "1.0.0"], ["engines": ["node": ">=99"]], ["os": ["linux"]],
    ["cpu": ["x64"]], ["dependencies": ["new": "*"]],
    ["optionalDependencies": ["@pnpm/exe.darwin-arm64": "3.0.0"]],
  ] {
    #expect(throws: (any Error).self) {
      try package.validateManifest(registryBytes(value.merging(changes) { _, new in new }))
    }
  }
}

@Test func npmCompatibilityUsesDeclaredTargetRuntimesAndPlatform() throws {
  let modern = BasePackageInputs.Runtimes(node: "24.21.0", npm: "11.19.0", rubygems: "4.0.7")
  let oldNode = BasePackageInputs.Runtimes(node: "18.0.0", npm: "11.19.0", rubygems: "4.0.7")
  let oldNPM = BasePackageInputs.Runtimes(node: "24.21.0", npm: "9.0.0", rubygems: "4.0.7")
  let decoder = JSONDecoder()
  let package = try decoder.decode(
    PackageRegistryMetadata.NPM.self, from: registryBytes(registryPackage()))
  try package.validate()
  #expect(try package.compatible(with: modern))
  #expect(try !package.compatible(with: oldNode))
  #expect(try !package.compatible(with: oldNPM))
  for restriction: [String: Any] in [["os": ["!darwin"]], ["os": ["linux"]], ["cpu": ["x64"]]] {
    let value = try decoder.decode(
      PackageRegistryMetadata.NPM.self,
      from: registryBytes(registryPackage(changes: restriction)))
    #expect(try !value.compatible(with: modern))
  }
  let native = try decoder.decode(
    PackageRegistryMetadata.NPM.self,
    from: registryBytes(
      registryPackage(
        name: PackageRegistryMetadata.nativePNPM,
        changes: ["os": ["darwin"], "cpu": ["arm64"]])))
  try native.validate()
  #expect(try native.compatible(with: modern))
}

@Test func registryPackagesRejectUntrackedDependenciesAndUnsafePayloads() throws {
  for changes: [String: Any] in [
    ["dependencies": ["unresolved": "*"]],
    ["optionalDependencies": ["unreviewed-native": "2.0.0"]],
    ["optionalDependencies": ["@pnpm/exe.darwin-arm64": "^2.0.0"]],
    ["dist": ["tarball": "https://other.test/a.tgz", "integrity": "sha512-AA=="]],
  ] {
    let package = try JSONDecoder().decode(
      PackageRegistryMetadata.NPM.self,
      from: registryBytes(registryPackage(changes: changes)))
    #expect(throws: (any Error).self) { try package.validate() }
  }
}

@Test func bundlerSelectionHandlesHistoricalNullsAndExcludesPrereleases() throws {
  let candidates = try PackageRegistryMetadata.gemVersions(
    registryBytes([
      [
        "number": "1.0.0", "platform": "ruby", "prerelease": false,
        "ruby_version": NSNull(), "rubygems_version": NSNull(), "sha": "old",
      ],
      [
        "number": "4.1.0.beta1", "platform": "ruby", "prerelease": true,
        "ruby_version": ">=3.2", "rubygems_version": ">=3.4.1", "sha": "future",
      ],
      [
        "number": "4.0.22", "platform": "ruby", "prerelease": false,
        "ruby_version": ">=3.2", "rubygems_version": ">=3.4.1", "sha": "current",
      ],
      [
        "number": "2.4.22", "platform": "ruby", "prerelease": false,
        "ruby_version": ">=2.6", "rubygems_version": ">=3.0.1", "sha": "compatible",
      ],
    ]), requested: nil)
  #expect(candidates.map(\.number) == ["4.0.22", "2.4.22", "1.0.0"])
  #expect(try !candidates[0].compatible(ruby: "2.7.8", rubygems: "3.1.6"))
  #expect(try candidates[1].compatible(ruby: "2.7.8", rubygems: "3.1.6"))
  #expect(throws: (any Error).self) {
    try candidates[2].compatible(ruby: "2.7.8", rubygems: "3.1.6")
  }
}

@Test func nativePackageDeploymentComesFromTheMachOHeader() throws {
  var data = Data(repeating: 0, count: 56)
  func field(_ value: UInt32, _ offset: Int) {
    var number = value.littleEndian
    withUnsafeBytes(of: &number) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
  }
  field(0xFEED_FACF, 0)
  field(0x0100_000C, 4)
  field(2, 12)
  field(1, 16)
  field(24, 20)
  field(0x32, 32)
  field(24, 36)
  field(1, 40)
  field(0x001A_0201, 44)
  #expect(try BasePackageResolution.minimumMacOS(data) == MacOSVersion("26.2.1"))
  #expect(try BasePackageResolution.minimumMacOS(data) > MacOSVersion("15.6.1"))
  field(2, 40)
  #expect(throws: (any Error).self) { try BasePackageResolution.minimumMacOS(data) }
  field(1, 40)
  field(1, 52)
  #expect(throws: (any Error).self) { try BasePackageResolution.minimumMacOS(data) }
}

@Test func payloadDownloadsRejectUnsafeURLsAndUnboundedSizes() throws {
  try HTTPFile.validate(URL(string: "https://registry.npmjs.org/file.tgz")!, maximumBytes: 1 << 20)
  for url in [
    "http://example.test/file", "https://user@example.test/file", "https://example.test:444/file",
    "https://example.test/file?token=test", "https://example.test/file#fragment",
  ] {
    #expect(throws: (any Error).self) {
      try HTTPFile.validate(URL(string: url)!, maximumBytes: 100)
    }
  }
  for size: UInt64 in [0, (512 << 20) + 1] {
    #expect(throws: (any Error).self) {
      try HTTPFile.validate(URL(string: "https://example.test/file")!, maximumBytes: size)
    }
  }
}

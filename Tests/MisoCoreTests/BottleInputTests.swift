import Darwin
import Foundation
import Testing

@testable import MisoCore

private func bottleFormula(
  name: String = "example", version: String = "1.2.3", revision: Int = 0, rebuild: Int = 0,
  sourceSHA256: String = String(repeating: "b", count: 64)
) -> HomebrewResolution.Formula {
  HomebrewResolution.Formula(
    name: name, version: version, revision: revision,
    dependencies: [], systemDependencies: [],
    bottle: .init(
      tag: "arm64_tahoe",
      url: URL(string: "https://ghcr.io/bottle")!, sha256: String(repeating: "a", count: 64),
      cellar: ":any", rebuild: rebuild),
    sourceURL: URL(
      string:
        "https://raw.githubusercontent.com/Homebrew/homebrew-core/\(String(repeating: "d", count: 40))/Formula/e/example.rb"
    )!,
    sourceSHA256: sourceSHA256,
    metadataSHA256: String(repeating: "c", count: 64),
    tapCommit: String(repeating: "d", count: 40), kegOnly: false, hasPostInstall: false)
}

@Test func bottleSourcesMustMatchBootstrapCoreBeforeInstallation() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let core = try GuestVolume(temporary.url)
  let source = Data("class Example < Formula\nend\n".utf8)
  try SafeFile.writeNew(
    source, to: Artifacts.makeParents(for: "Formula/e/example.rb", under: temporary.url))
  let formula = bottleFormula(sourceSHA256: SafeFile.sha256(source))
  try HomebrewBottleInputs.verifyFormulaSources([formula], core: core)
  try SafeFile.replace(Data("changed".utf8), at: core.path("Formula/e/example.rb"))
  #expect(throws: MisoError.self) {
    try HomebrewBottleInputs.verifyFormulaSources([formula], core: core)
  }
}

@Test func mirroredCoreTrustControlChecksOnlyTheCoreTap() {
  #expect(
    BaseBottles.coreTrustControl.contains(
      "Homebrew::Trust.trusted_tap?(Tap.fetch('homebrew/core'))"))
  #expect(BaseBottles.coreTrustControl.contains("abort 'Untrusted core snapshot'"))
}

private func bottleIndex(annotations changes: [String: String] = [:], duplicate: Bool = false)
  throws -> Data
{
  let annotations = [
    "org.opencontainers.image.ref.name": "1.2.3_2.arm64_tahoe.1",
    "sh.brew.bottle.digest": String(repeating: "a", count: 64),
    "sh.brew.bottle.size": "128", "sh.brew.tab": "{\"runtime_dependencies\":[]}",
  ].merging(changes) { _, new in new }
  return try JSONSerialization.data(withJSONObject: [
    "schemaVersion": 2,
    "manifests": duplicate
      ? [["annotations": annotations], ["annotations": annotations]]
      : [["annotations": annotations]],
  ])
}

@Test func bottleOCIIdentityBindsVersionRevisionRebuildDigestAndSize() throws {
  let formula = bottleFormula(revision: 2, rebuild: 1)
  let tab = try HomebrewBottleInputs.parseIndex(bottleIndex(), formula: formula, bytes: 128)
  #expect(tab == .object(["runtime_dependencies": .array([])]))
  for changes in [
    ["sh.brew.bottle.digest": String(repeating: "e", count: 64)],
    ["sh.brew.bottle.size": "129"],
    ["org.opencontainers.image.ref.name": "1.2.3_2.arm64_tahoe"],
    ["org.opencontainers.image.ref.name": "1.2.3.arm64_tahoe.1"],
    ["org.opencontainers.image.ref.name": "1.2.3_2.arm64_sequoia.1"],
    ["sh.brew.tab": "[]"],
  ] {
    #expect(throws: (any Error).self) {
      try HomebrewBottleInputs.parseIndex(
        bottleIndex(annotations: changes), formula: formula, bytes: 128)
    }
  }
  #expect(throws: (any Error).self) {
    try HomebrewBottleInputs.parseIndex(bottleIndex(duplicate: true), formula: formula, bytes: 128)
  }
}

@Test func bottleRegistryTagsKeepRevisionAndRebuildDistinct() throws {
  #expect(
    try HomebrewRegistry.index(bottleFormula(name: "node@24", revision: 2, rebuild: 3))
      .absoluteString == "https://ghcr.io/v2/homebrew/core/node/24/manifests/1.2.3_2-3")
  #expect(
    try HomebrewRegistry.index(bottleFormula(name: "c++util")).absoluteString
      == "https://ghcr.io/v2/homebrew/core/cxxutil/manifests/1.2.3")
  for version in ["../bad", "1+2", "", String(repeating: "1", count: 129)] {
    #expect(throws: MisoError.self) { try HomebrewRegistry.index(bottleFormula(version: version)) }
  }
}

@Test func bottleSidecarOmitsRebuildButArchiveRetainsIt() throws {
  let payload = HomebrewBottleInputs.Payload(
    formula: bottleFormula(revision: 2, rebuild: 1),
    archive: .init(path: "example.tar.gz", bytes: 128, sha256: String(repeating: "a", count: 64)),
    index: .init(
      path: "example.tar.index.json", bytes: 100, sha256: String(repeating: "b", count: 64)),
    tab: .object(["runtime_dependencies": .array([])]))
  #expect(payload.filename == "example--1.2.3_2.arm64_tahoe.bottle.1.tar.gz")
  #expect(payload.sidecarName == "example--1.2.3_2.arm64_tahoe.bottle.json")
  #expect(
    payload.sidecar
      == .object([
        "example": .object([
          "bottle": .object([
            "tags": .object(["arm64_tahoe": .object(["tab": payload.tab])])
          ])
        ])
      ]))
}

@Test func bottleRuntimeDependenciesMustBeResolvedAndSelected() throws {
  let formula = bottleFormula(revision: 2)
  let dependency: JSONValue = .object([
    "full_name": .string("example"),
    "version": .string("1.2.3"), "revision": .integer(2),
  ])
  let tab: JSONValue = .object(["runtime_dependencies": .array([dependency])])
  try HomebrewBottleInputs.validateDependencies(
    tab, formulae: ["example": formula], selected: ["example"])
  #expect(throws: (any Error).self) {
    try HomebrewBottleInputs.validateDependencies(tab, formulae: ["example": formula], selected: [])
  }
  try HomebrewBottleInputs.validateDependencies(
    tab, formulae: ["example": bottleFormula()], selected: ["example"])
  #expect(throws: (any Error).self) {
    try HomebrewBottleInputs.validateDependencies(.object([:]), formulae: [:], selected: [])
  }
}

@Test func bottleInstalledInventoryRejectsMultipleVersionsAndDuplicates() throws {
  #expect(try BaseBottles.installedVersions("").isEmpty)
  #expect(
    try BaseBottles.installedVersions("example 1.2.3_2\nnode@24 24.1.0\n")
      == ["example": "1.2.3_2", "node@24": "24.1.0"])
  for invalid in ["example", "example 1.0 2.0", "example 1.0\nexample 1.0", "../x 1.0"] {
    #expect(throws: (any Error).self) { try BaseBottles.installedVersions(invalid) }
  }
}

@Test func bottleSymlinksResolveWithinTheInstallationPrefix() throws {
  let interpreter = TarPayload.Entry(
    path: "awscli/2.0/libexec/bin/python3",
    kind: UInt16(S_IFLNK), mode: 0o755, bytes: 0,
    link: "../../../../../opt/python@3.14/bin/python3.14")
  let alias = TarPayload.Entry(
    path: "awscli/2.0/libexec/bin/python",
    kind: UInt16(S_IFLNK), mode: 0o755, bytes: 0, link: "python3")
  #expect(throws: (any Error).self) { try TarPayload.validate([alias, interpreter]) }
  try TarPayload.validate([alias, interpreter], pathPrefix: "Cellar")
  let escape = TarPayload.Entry(
    path: interpreter.path, kind: interpreter.kind,
    mode: interpreter.mode, bytes: 0, link: "../../../../../../outside")
  #expect(throws: (any Error).self) {
    try TarPayload.validate([alias, escape], pathPrefix: "Cellar")
  }
  #expect(throws: (any Error).self) {
    try TarPayload.validate([alias, interpreter], pathPrefix: "../outside")
  }
}

@Test func tarHardlinksRequireOwnedRegularTargets() throws {
  let file = TarPayload.Entry(
    path: "gcc/1/bin/compiler", kind: UInt16(S_IFREG),
    mode: 0o555, bytes: 12, link: nil)
  let alias = TarPayload.Entry(
    path: "gcc/1/bin/cc", kind: UInt16(S_IFREG),
    mode: 0o555, bytes: 0, link: nil, hardlink: file.path)
  try TarPayload.validate([file, alias])
  try TarPayload.validate([file, alias], pathPrefix: "Cellar")
  for target in ["../outside", "missing", alias.path] {
    let bad = TarPayload.Entry(
      path: alias.path, kind: alias.kind, mode: alias.mode,
      bytes: 0, link: nil, hardlink: target)
    #expect(throws: (any Error).self) { try TarPayload.validate([file, bad]) }
  }
  let symlink = TarPayload.Entry(
    path: file.path, kind: UInt16(S_IFLNK), mode: file.mode,
    bytes: 0, link: "other")
  #expect(throws: (any Error).self) { try TarPayload.validate([symlink, alias]) }
}

@Test func lifecycleProbesFollowResolvedVersionsAndFormulaNames() throws {
  let probes = try HomebrewLifecycle.probes([
    bottleFormula(name: "node@22", version: "22.18.0"),
    bottleFormula(name: "python@3.13", version: "3.13.7"),
    bottleFormula(name: "awscli", version: "2.37.3"),
  ])
  #expect(
    probes.first { $0.name == "node@22" }?.arguments.first
      == "/opt/homebrew/opt/node@22/bin/node")
  #expect(probes.first { $0.name == "node@22" }?.arguments.last?.contains("v22.18.0") == true)
  #expect(
    probes.first { $0.name == "python@3.13" }?.arguments.first
      == "/opt/homebrew/opt/python@3.13/bin/python3.13")
  #expect(
    probes.first { $0.name == "awscli" }?.arguments
      == ["/opt/homebrew/opt/awscli/bin/aws", "--version"])
  #expect(probes.contains { $0.name == "node@22-npm" })
  #expect(throws: (any Error).self) {
    try HomebrewLifecycle.probes([bottleFormula(name: "node", version: "1.0\";exit(0)")])
  }
  #expect(throws: (any Error).self) {
    try HomebrewLifecycle.probes([bottleFormula(name: "python@3.13", version: "3.13-rc1")])
  }
}

@Test func bottleCompatibilityRejectsAnIncompatibleNewerDependency() throws {
  let dependency: JSONValue = .object([
    "full_name": .string("example"), "version": .string("1.2.0"),
    "revision": .integer(0), "compatibility_version": .integer(5),
  ])
  let tab: JSONValue = .object(["runtime_dependencies": .array([dependency])])
  let formulae = ["example": bottleFormula()]
  try HomebrewBottleInputs.validateDependencies(
    tab, formulae: formulae, selected: ["example"], compatibilityVersions: ["example": 5])
  #expect(throws: MisoError.self) {
    try HomebrewBottleInputs.validateDependencies(
      tab, formulae: formulae, selected: ["example"], compatibilityVersions: ["example": 6])
  }
  let target = RestoreProfile.supported[0].release
  #expect(
    try HomebrewResolution.compatibilityVersion(
      Data("{\"compatibility_version\":6}".utf8), target: target) == 6)
  #expect(
    try HomebrewResolution.compatibilityVersion(
      Data("{\"compatibility_version\":null}".utf8), target: target) == nil)
  #expect(throws: MisoError.self) {
    try HomebrewResolution.compatibilityVersion(
      Data("{\"compatibility_version\":-1}".utf8), target: target)
  }
}

@Test func bottleCompatibilityUsesEachSelectedDependencyOwnRequirements() throws {
  func tab(_ direct: JSONValue) -> JSONValue {
    .object([
      "runtime_dependencies": .array([
        .object([
          "full_name": .string("example"), "version": .string("1.2.0"),
          "revision": .integer(0), "compatibility_version": .integer(5),
          "declared_directly": direct,
        ])
      ])
    ])
  }
  let formulae = ["example": bottleFormula()]
  try HomebrewBottleInputs.validateDependencies(
    tab(.bool(false)), formulae: formulae, selected: ["example"],
    compatibilityVersions: ["example": 6])
  for declaration in [JSONValue.bool(true), .string("false")] {
    #expect(throws: MisoError.self) {
      try HomebrewBottleInputs.validateDependencies(
        tab(declaration), formulae: formulae, selected: ["example"],
        compatibilityVersions: ["example": 6])
    }
  }
  #expect(throws: MisoError.self) {
    try HomebrewBottleInputs.validateDependencies(
      tab(.bool(false)), formulae: formulae, selected: ["example"],
      compatibilityVersions: ["example": 6], directDependencies: ["example"])
  }
}

import CryptoKit
import Foundation
import Testing

@testable import MisoCore

@Test func npmIntegrityStreamsAndHonorsCancellation() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let file = temporary.url.appendingPathComponent("package.tgz")
  let bytes = Data(repeating: 83, count: (8 << 20) + 7)
  try SafeFile.writeNew(bytes, to: file)
  #expect(
    try BasePackageInputs.integrity(file) == "sha512-"
      + Data(SHA512.hash(data: bytes)).base64EncodedString())
  let cancellation = try CancellationToken()
  cancellation.cancel()
  #expect(throws: CancellationError.self) {
    try BasePackageInputs.integrity(file, cancellation: cancellation)
  }
}

@Test func npmMetadataRejectsForeignPlatformPackages() throws {
  for (os, cpu, accepted) in [
    (["darwin"], ["arm64"], true), (["!linux"], ["!x64"], true),
    (["darwin", "!darwin"], ["arm64"], false), (["linux"], ["arm64"], false),
    (["darwin"], ["x64"], false), (["any"], ["arm64"], true),
  ] {
    let metadata = BasePackageInputs.NPMMetadata(
      name: "package", version: "1.0.0",
      dist: .init(integrity: "unused"), os: os, cpu: cpu)
    if accepted {
      try metadata.requireTarget()
    } else {
      #expect(throws: (any Error).self) { try metadata.requireTarget() }
    }
  }
}

@Test func npmListingRequiresVersionsAndNoProblems() throws {
  #expect(
    try BasePackages.installedVersions(
      #"{"dependencies":{"@pnpm/exe.darwin-arm64":{"version":"12.6.0"},"yarn":{"version":"1.22.22"}}}"#
    )
      == ["@pnpm/exe.darwin-arm64": "12.6.0", "yarn": "1.22.22"])
  #expect(try BasePackages.installedVersions("{}") == [:])
  for invalid in [#"{"problems":["missing dependency"]}"#, #"{"dependencies":{"yarn":{}}}"#] {
    #expect(throws: (any Error).self) { try BasePackages.installedVersions(invalid) }
  }
}

@Test func packagePlansRejectUnboundedNamesAndDuplicateRequests() throws {
  let record = ImageBundle.FileRecord(
    path: "input", bytes: 1, sha256: String(repeating: "a", count: 64))
  let bundler = BasePackageInputs.Package(
    name: "bundler", version: "4.0.21", metadata: record, payload: record)
  for (name, formula, accepted) in [
    ("@pnpm/exe.darwin-arm64", "node@24", true), ("yarn", "node", true),
    ("../yarn", "node@24", false), ("yarn", "node@24 --bad", false),
  ] {
    let npm = BasePackageInputs.Package(
      name: name, version: "1.0.0", metadata: record, payload: record)
    let plan = BasePackageInputs.Plan(
      schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"),
      rubyVersion: "4.0.7", nodeFormula: formula, bundler: bundler, npm: [npm])
    if accepted {
      try plan.validate()
    } else {
      #expect(throws: (any Error).self) { try plan.validate() }
    }
    #expect(throws: (any Error).self) {
      try BasePackageInputs.Plan(
        schemaVersion: 1, target: plan.target, rubyVersion: plan.rubyVersion,
        nodeFormula: formula, bundler: bundler, npm: [npm, npm]
      ).validate()
    }
  }
}

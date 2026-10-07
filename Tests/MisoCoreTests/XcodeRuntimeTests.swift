import CryptoKit
import Foundation
import Testing

@testable import MisoCore

private let runtimeRequirement = XcodeRuntime.Requirement(
  platform: .iOS, version: "27.0", build: "24A434")

private func runtimeCatalog() throws -> Data {
  let file = Bundle.module.url(
    forResource: "ios-24A434", withExtension: "jwt", subdirectory: "Fixtures")!
  return try AppleAssetCatalog.verify(
    Data(contentsOf: file), at: Date(timeIntervalSince1970: 1_791_000_000))
}

@Test func simulatorCatalogBindsPlatformVersionBuildAndArchitecture() throws {
  let payload = try runtimeCatalog()
  let selected = try XcodeRuntime.select(payload, requirement: runtimeRequirement)
  #expect(selected.downloadBytes == 8_053_063_680)
  #expect(selected.assetType == "com.apple.MobileAsset.iOSSimulatorRuntime")
  for requirement in [
    XcodeRuntime.Requirement(platform: .watchOS, version: "27.0", build: "24A434"),
    XcodeRuntime.Requirement(platform: .iOS, version: "27.1", build: "24A434"),
    XcodeRuntime.Requirement(platform: .iOS, version: "27.0", build: "24A435"),
  ] {
    #expect(throws: MisoError.self) { try XcodeRuntime.select(payload, requirement: requirement) }
  }
  var object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
  var assets = object["Assets"] as! [[String: Any]]
  assets[0]["Architectures"] = ["arm64", "x86_64"]
  object["Assets"] = assets
  #expect(throws: MisoError.self) {
    try XcodeRuntime.select(
      JSONSerialization.data(withJSONObject: object), requirement: runtimeRequirement)
  }
}

@Test func simulatorPreparationUsesExplicitRuntimeSelectionsAcrossXcodeVersions() throws {
  try runtimeRequirement.validate(.init())
  var configuration = XcodeConfiguration()
  configuration.platforms = [.watchOS]
  #expect(throws: MisoError.self) { try runtimeRequirement.validate(configuration) }
  for requirement in [
    XcodeRuntime.Requirement(platform: .iOS, version: "latest", build: "24A434"),
    XcodeRuntime.Requirement(platform: .iOS, version: "27.0", build: "../24A434"),
  ] {
    #expect(throws: MisoError.self) { try requirement.validate(.init()) }
  }
  configuration = XcodeConfiguration()
  configuration.version = "27.1"
  configuration.build = "27A9275"
  try XcodeRuntime.Requirement(platform: .iOS, version: "27.1", build: "24B91").validate(
    configuration)
  try XcodeRuntime.Requirement(platform: .watchOS, version: "27.0", build: "24R360").validate(
    configuration)
  try runtimeRequirement.validate(configuration)
  configuration.version = "27.2"
  configuration.build = "27B5028f"
  try XcodeRuntime.Requirement(platform: .iOS, version: "27.2", build: "24B5089g").validate(
    configuration)
}

@Test func simulatorRestoreInspectionRequiresTheArm64ImageDigest() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let root = directory.url
  let restore = root.appendingPathComponent("AssetData/Restore")
  try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
  func write(_ relative: String, _ value: [String: Any]) throws {
    try SafeFile.writeNew(
      PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
      to: root.appendingPathComponent(relative))
  }
  try write(
    "Info.plist",
    [
      "CFBundleIdentifier": "com.apple.MobileAsset.iOSSimulatorRuntime",
      "MobileAssetProperties": [
        "Build": "24A434", "SimulatorVersion": "27.0", "Architectures": ["arm64"],
      ],
    ])
  let bytes = Data("authenticated disk fixture".utf8)
  let disk = restore.appendingPathComponent("runtime.dmg")
  try SafeFile.writeNew(bytes, to: disk)
  try write(
    "AssetData/Restore/BuildManifest.plist",
    [
      "ProductBuildVersion": "24A434",
      "BuildIdentities": [
        [
          "Info": [
            "DeviceClass": "macoscryptexap", "Variant": "Arm64Only Customer Simulator Runtime",
          ],
          "Manifest": [
            "Cryptex1,GenericDmg": [
              "Info": ["Path": "runtime.dmg", "HashMethod": "sha2-384"],
              "Digest": Data(SHA384.hash(data: bytes)),
            ]
          ],
        ]
      ],
    ])
  #expect(
    try XcodeRuntime.inspect(root, requirement: runtimeRequirement, cancellation: nil) == disk)
  try SafeFile.replace(Data("changed".utf8), at: disk)
  #expect(throws: MisoError.self) {
    try XcodeRuntime.inspect(root, requirement: runtimeRequirement, cancellation: nil)
  }
}

@Test func simulatorAEALimitIncludesAuthenticatedArchiveFraming() throws {
  let file = Bundle.module.url(
    forResource: "tvos-24J360", withExtension: "jwt", subdirectory: "Fixtures")!
  let payload = try AppleAssetCatalog.verify(
    Data(contentsOf: file), at: Date(timeIntervalSince1970: 1_791_000_000))
  let asset = try XcodeRuntime.select(
    payload, requirement: .init(platform: .tvOS, version: "27.0", build: "24J360"))
  let authenticatedRawBytes: UInt64 = 3_699_987_224
  #expect(authenticatedRawBytes > asset.expandedBytes + (1 << 20))
  #expect(authenticatedRawBytes <= asset.decryptionLimit)
  #expect(asset.decryptionLimit <= (64 << 30) + (1 << 20))
}

@Test func componentPayloadPreservesItsTreeAndRejectsExistingDestinations() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let source = temporary.url.appendingPathComponent("source")
  let target = temporary.url.appendingPathComponent("target")
  try SafeFile.makeDirectory(source, mode: 0o755)
  try SafeFile.makeDirectory(target)
  let nested = source.appendingPathComponent("nested")
  try SafeFile.makeDirectory(nested, mode: 0o755)
  try SafeFile.writeNew(Data("runtime payload".utf8), to: nested.appendingPathComponent("file"))
  try FileManager.default.createSymbolicLink(
    atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested/file")
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("journal"), operation: "test-runtime-copy")
  let receipt = try XcodeComponentPayload.copy(
    source, to: GuestVolume(target), path: "Library/Developer/example.simruntime", journal: journal)
  #expect(receipt.entries == 3)
  #expect(receipt.regularFiles == 1)
  #expect(receipt.logicalBytes == 15)
  #expect(
    try FileManager.default.destinationOfSymbolicLink(
      atPath: target.appendingPathComponent("Library/Developer/example.simruntime/link").path)
      == "nested/file")
  #expect(throws: MisoError.self) {
    try XcodeComponentPayload.copy(
      source, to: GuestVolume(target), path: "Library/Developer/example.simruntime",
      journal: journal)
  }
  try journal.finish(receipt)
}

@Test func metalEnvironmentPreservesProfilesAndRejectsConflictingSelection() throws {
  let identifier = try XcodeMetalInstallation.identifier(.init())
  let original = Data("export EXAMPLE=value".utf8)
  let expected = "export EXAMPLE=value\nexport TOOLCHAINS='moe.uwucocoa.miso.metal.27A266a'\n"
  #expect(
    try XcodeMetalInstallation.shellProfile(original, identifier: identifier) == Data(expected.utf8)
  )
  for previous in [Data("export TOOLCHAINS=custom\n".utf8), Data([0xFF])] {
    #expect(throws: MisoError.self) {
      try XcodeMetalInstallation.shellProfile(previous, identifier: identifier)
    }
  }
  #expect(throws: MisoError.self) {
    try XcodeMetalInstallation.shellProfile(Data(), identifier: "invalid'\ncommand")
  }
}

import CryptoKit
import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func metalBuildFollowsApplesXcodeComponentMapping() throws {
  var configuration = XcodeConfiguration()
  configuration.version = "27.2"
  configuration.build = "27B5028f"
  let mapping: [String: Any] = [
    "affinity": "available", "assetType": "metalToolchain",
    "xcodeBuildUpdate": "27B5028f", "assetBuildUpdate": "27B5028e",
  ]
  let asset: [String: Any] = [
    "assetType": "metalToolchain", "assetBuildUpdate": "27B5028e",
    "downloadMethod": "mobileAsset", "contentType": "cryptexDiskImage",
  ]
  func index(_ mappings: [[String: Any]], _ assets: [[String: Any]]) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "xcodeToOtherDownloadablesMappings": mappings, "otherDownloadables": assets,
      ],
      format: .xml, options: 0)
  }
  #expect(
    try XcodeComponentIndex.metalBuild(index([mapping], [asset]), configuration: configuration)
      == "27B5028e")
  var ambiguous = mapping
  ambiguous["assetBuildUpdate"] = "27B5019j"
  for data in [
    try index([], [asset]), try index([mapping], []), try index([mapping, ambiguous], [asset]),
  ] {
    #expect(throws: MisoError.self) {
      try XcodeComponentIndex.metalBuild(data, configuration: configuration)
    }
  }
  var preferred = mapping
  preferred["affinity"] = "preferred"
  #expect(
    try XcodeComponentIndex.metalBuild(
      index([preferred, ambiguous], [asset]), configuration: configuration)
      == "27B5028e")
}

@Test func nativeXcodeComponentIndexProbe() throws {
  guard let path = ProcessInfo.processInfo.environment["MISO_XCODE_COMPONENT_INDEX_PROBE"] else {
    return
  }
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  for (version, build, metal) in [
    ("27.0", "27A5194q", "27A5194o"), ("27.0", "27A5209h", "27A5209h"),
    ("27.0", "27A5218g", "27A5218h"), ("27.0", "27A5228h", "27A5228f"),
    ("27.0", "27A5237l", "27A5237l"), ("27.0", "27A5252f", "27A5252f"),
    ("27.0", "27A266a", "27A266a"), ("27.1", "27A9269", "27A266a"),
    ("27.1", "27A9275", "27A266a"), ("27.2", "27B5019j", "27B5019j"),
    ("27.2", "27B5028f", "27B5028e"),
  ] {
    var configuration = XcodeConfiguration()
    configuration.version = version
    configuration.build = build
    #expect(try XcodeComponentIndex.metalBuild(data, configuration: configuration) == metal)
  }
}

@Test func metalAssetInspectionBindsBuildAndContainsDiskPaths() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let root = try GuestVolume(directory.url)
  let build = "27A266a"
  try root.mergePlist(
    "Info.plist",
    values: [
      "CFBundleIdentifier": "com.apple.MobileAsset.MetalToolchain",
      "MobileAssetProperties": ["Build": build],
    ], uid: geteuid(), gid: getegid())
  func manifest(_ path: String, build: String = "27A266a") throws {
    try root.mergePlist(
      "AssetData/Restore/BuildManifest.plist",
      values: [
        "ProductBuildVersion": build,
        "BuildIdentities": ["macoscryptexap", "x86macoscryptexap"].map { device in
          [
            "Info": [
              "DeviceClass": device, "Variant": "Customer Metal Toolchain", "BuildNumber": build,
            ],
            "Manifest": [
              "Cryptex1,GenericDmg": [
                "Info": ["Path": path, "HashMethod": "sha2-384"],
                "Digest": Data(SHA384.hash(data: Data([1]))),
              ]
            ],
          ]
        },
      ], uid: geteuid(), gid: getegid())
  }
  try root.write("AssetData/Restore/metal.dmg", data: Data([1]), uid: geteuid(), gid: getegid())
  try manifest("metal.dmg")
  #expect(try XcodeMetal.inspect(directory.url, build: build).lastPathComponent == "metal.dmg")
  #expect(throws: MisoError.self) { try XcodeMetal.inspect(directory.url, build: "27A9269") }
  try manifest("metal.dmg", build: "27A9269")
  #expect(throws: MisoError.self) { try XcodeMetal.inspect(directory.url, build: build) }
  for path in ["../metal.dmg", "/metal.dmg", "metal.aar"] {
    try manifest(path)
    #expect(throws: MisoError.self) { try XcodeMetal.inspect(directory.url, build: build) }
  }
  try manifest("metal.dmg")
  try root.write("AssetData/Restore/metal.dmg", data: Data([2]), uid: geteuid(), gid: getegid())
  #expect(throws: MisoError.self) { try XcodeMetal.inspect(directory.url, build: build) }
}

@Test func metalPreparationRejectsIncompleteReplayBeforeCreatingOutput() async throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let output = directory.url.appendingPathComponent("output")
  await #expect(throws: MisoError.self) {
    try await XcodeMetal.prepare(
      catalog: directory.url.appendingPathComponent("catalog"), output: output)
  }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func nativeMetalRegistrationMatchesApplesCatalog() throws {
  guard ProcessInfo.processInfo.environment["MISO_NATIVE_METAL_PROBE"] == "1" else { return }
  let fixture = try #require(
    Bundle.module.url(
      forResource: "metal-27A266a", withExtension: "jwt", subdirectory: "Fixtures"))
  let payload = try AppleAssetCatalog.verify(
    Data(contentsOf: fixture), at: Date(timeIntervalSince1970: 1_791_000_000))
  let catalog = try MetalAssetRegistration.catalog(payload, build: "27A266a")
  #expect(catalog.identifier == "389a215aea89fda945178f9fb8bcdc6aa0e20570")
  #expect(catalog.attributes["_Measurement"] is Data)
  #expect(catalog.attributes["_Measurement-SHA256"] is Data)
  #expect(catalog.attributes["AssetType"] as? String == MetalAssetRegistration.type)
  #expect(catalog.assetPath.hasSuffix("/389a215aea89fda945178f9fb8bcdc6aa0e20570.asset"))
  var changed = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
  changed["Transformations"] = ["_Measurement": "unsupported"]
  #expect(throws: MisoError.self) {
    try MetalAssetRegistration.catalog(
      JSONSerialization.data(withJSONObject: changed), build: "27A266a")
  }
  #expect(throws: MisoError.self) {
    try MetalAssetRegistration.catalog(payload, build: "27B5019j")
  }
}

@Test func nativeMetalInstallationInMountedGuest() throws {
  guard let path = ProcessInfo.processInfo.environment["MISO_METAL_INSTALLATION_PROBE"] else {
    return
  }
  try #require(geteuid() == 0)
  let settings = try JSON.read([String: String].self, from: URL(fileURLWithPath: path))
  let inputs = URL(fileURLWithPath: try #require(settings["inputs"]))
  let data = try GuestVolume(URL(fileURLWithPath: try #require(settings["data"])))
  let output = URL(fileURLWithPath: try #require(settings["output"]))
  let input = try JSON.read(
    XcodeMetal.Receipt.self, from: inputs.appendingPathComponent("metal.json"))
  let account = try BaseImageStage.Account("admin", data: data)
  let journal = try ExecutionJournal(output: output, operation: "metal-installation-probe")
  let result = try XcodeMetalInstallation.copy(
    input, configuration: .init(), inputs: inputs, data: data, account: account, journal: journal)
  #expect(result.toolchainIdentifier == input.toolchainIdentifier)
  #expect(try !data.contains("Library/Developer/Toolchains/MISO-Metal-27A266a.xctoolchain"))
  #expect(
    try !data.contains("Users/admin/Library/LaunchAgents/moe.uwucocoa.miso.metal.environment.plist")
  )
  for profile in [".zshenv", ".zprofile"] {
    let bytes = try SafeFile.read(data.path("Users/admin/" + profile), limit: 1 << 20)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("TOOLCHAINS"))
  }
  try journal.finish(result)
}

@Test func metalMigrationPreservesUnrelatedGuestSettings() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let data = try GuestVolume(directory.url)
  let uid = max(geteuid(), 501)
  let gid = max(getegid(), 20)
  try data.mergePlist(
    "private/var/db/dslocal/nodes/Default/users/admin.plist",
    values: ["uid": [String(uid)], "gid": [String(gid)], "home": ["/Users/admin"]],
    uid: geteuid(), gid: getegid())
  let account = try BaseImageStage.Account("admin", data: data)
  let payload = "Library/Developer/MISO/Metal/27A266a"
  let wrapper = "Library/Developer/Toolchains/MISO-Metal-27A266a.xctoolchain"
  let identifier = "moe.uwucocoa.miso.metal.27A266a"
  try data.makeDirectories(payload + "/Metal.xctoolchain/usr", uid: geteuid(), gid: getegid())
  try data.mergePlist(
    wrapper + "/Info.plist",
    values: ["CFBundleIdentifier": identifier, "CompatibilityVersion": 2],
    uid: geteuid(), gid: getegid())
  #expect(
    symlink("/" + payload + "/Metal.xctoolchain/usr", try data.path(wrapper + "/usr").path) == 0)
  let profile = "Users/admin/.zprofile"
  try data.write(
    profile, data: Data("export OTHER=1\nexport TOOLCHAINS='\(identifier)'\n".utf8), uid: uid,
    gid: gid)
  let agent = "Users/admin/Library/LaunchAgents/moe.uwucocoa.miso.metal.environment.plist"
  try data.mergePlist(
    agent,
    values: [
      "Label": "moe.uwucocoa.miso.metal.environment",
      "ProgramArguments": ["/bin/launchctl", "setenv", "TOOLCHAINS", identifier],
    ],
    uid: uid, gid: gid)
  try XcodeMetalInstallation.removeLegacyRegistration(
    configuration: .init(), data: data, account: account)
  #expect(try !data.contains(wrapper))
  #expect(try !data.contains(payload))
  #expect(try !data.contains(agent))
  #expect(try SafeFile.read(data.path(profile), limit: 1024) == Data("export OTHER=1\n".utf8))
  try data.mergePlist(
    wrapper + "/Info.plist", values: ["CFBundleIdentifier": "unrelated"], uid: geteuid(),
    gid: getegid())
  #expect(throws: (any Error).self) {
    try XcodeMetalInstallation.removeLegacyRegistration(
      configuration: .init(), data: data, account: account)
  }
  #expect(try data.contains(wrapper))
}

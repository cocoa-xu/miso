import CryptoKit
import Darwin
import Foundation
import Testing

@testable import MisoCore

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

@Test func metalFinalizationMakesOnlyTheOwnedRegistrationTraversable() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let data = try GuestVolume(directory.url)
  let configuration = XcodeConfiguration()
  let payload = "Library/Developer/MISO/Metal/27A266a/Metal.xctoolchain/usr"
  let registration = "Library/Developer/Toolchains/MISO-Metal-27A266a.xctoolchain"
  try data.makeDirectories(payload, uid: geteuid(), gid: getegid())
  try data.mergePlist(
    registration + "/Info.plist",
    values: [
      "CFBundleIdentifier": try XcodeMetalInstallation.identifier(configuration),
      "CompatibilityVersion": 2,
    ], uid: geteuid(), gid: getegid())
  let link = try data.path(registration + "/usr")
  #expect(chmod(try data.path(payload).path, 0o700) == 0)
  #expect(symlink("/" + payload, link.path) == 0)
  #expect(lchmod(link.path, 0o700) == 0)
  try XcodeMetalInstallation.finalizeRegistration(configuration: configuration, data: data)
  #expect(try FileMetadata.inspect(link).st_mode & 0o777 == 0o755)
  #expect(try FileMetadata.inspect(data.path(payload)).st_mode & 0o777 == 0o700)
  #expect(unlink(link.path) == 0)
  #expect(symlink("/unrelated", link.path) == 0)
  #expect(lchmod(link.path, 0o700) == 0)
  #expect(throws: MisoError.self) {
    try XcodeMetalInstallation.finalizeRegistration(configuration: configuration, data: data)
  }
  #expect(try FileMetadata.inspect(link).st_mode & 0o777 == 0o700)
}

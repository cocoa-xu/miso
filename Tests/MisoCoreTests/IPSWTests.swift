import Darwin
import Foundation
import Testing
import ZIPFoundation

@testable import MisoCore

struct TemporaryDirectory {
  let url: URL
  init() throws {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw MisoError.system("Resolve temporary directory", errno)
    }
    defer { free(resolved) }
    url = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(UUID().uuidString)
    try SafeFile.makeDirectory(url)
  }
  func remove() { try? FileManager.default.removeItem(at: url) }
}

func restoreMetadata(_ profile: RestoreProfile) -> (manifest: [String: Any], restore: [String: Any])
{
  let identity: [String: Any] = [
    "Ap,ProductType": profile.productType, "ProductMarketingVersion": profile.release.version,
    "ApChipID": "0xfe00", "ApBoardID": "0x20", "ApSecurityDomain": "0x1",
    "Info": [
      "DeviceClass": profile.deviceClass, "Variant": profile.restoreVariant,
      "BuildNumber": profile.release.build, "RestoreBehavior": "Erase", "ContentEncoding": "aea",
      "VirtualMachineMinCPUCount": 2, "VirtualMachineMinMemorySizeMB": 4096,
      "VirtualMachineMinHostOS": "15.0",
    ],
    "Manifest": Dictionary(
      uniqueKeysWithValues: profile.requiredComponents.enumerated().map {
        ($0.element, ["Info": ["Path": "components/\($0.offset)"]])
      }),
  ]
  let common: [String: Any] = [
    "ProductVersion": profile.release.version, "ProductBuildVersion": profile.release.build,
    "SupportedProductTypes": [profile.productType],
  ]
  var manifest = common
  var restore = common
  manifest["ManifestVersion"] = 0
  manifest["BuildIdentities"] = [identity]
  restore["DeviceMap"] = [
    [
      "BoardConfig": profile.deviceClass, "CPID": profile.chipID, "BDID": profile.boardID,
      "SDOM": profile.securityDomain,
    ]
  ]
  return (manifest, restore)
}

func zipFixture(at url: URL, members: [(String, Data)], compression: CompressionMethod = .deflate)
  throws
{
  let archive = try Archive(url: url, accessMode: .create)
  for (name, content) in members {
    try archive.addEntry(
      with: name, type: .file, uncompressedSize: Int64(content.count),
      compressionMethod: compression
    ) { position, count in
      content.subdata(in: Int(position)..<Int(position) + count)
    }
  }
}

@Test(arguments: RestoreProfile.supported)
func restoreSelection(_ profile: RestoreProfile) throws {
  var metadata = restoreMetadata(profile)
  #expect(
    try RestoreInspection.select(manifest: metadata.manifest, restore: metadata.restore).profile
      == profile)
  metadata.manifest["ManifestVersion"] = false
  #expect(throws: (any Error).self) {
    try RestoreInspection.select(manifest: metadata.manifest, restore: metadata.restore)
  }
  metadata.manifest["ManifestVersion"] = 0.0
  #expect(throws: (any Error).self) {
    try RestoreInspection.select(manifest: metadata.manifest, restore: metadata.restore)
  }
  metadata.manifest["ManifestVersion"] = 0
  metadata.restore["ProductBuildVersion"] = "unknown"
  #expect(throws: (any Error).self) {
    try RestoreInspection.select(manifest: metadata.manifest, restore: metadata.restore)
  }
}

@Test func inspectArchive() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let profile = RestoreProfile.supported[0]
  let metadata = restoreMetadata(profile)
  let manifest = try PropertyListSerialization.data(
    fromPropertyList: metadata.manifest, format: .xml, options: 0)
  let restore = try PropertyListSerialization.data(
    fromPropertyList: metadata.restore, format: .binary, options: 0)
  let members =
    [("BuildManifest.plist", manifest), ("Restore.plist", restore)]
    + profile.requiredComponents.indices.map { ("components/\($0)", Data([1])) }
  let url = directory.url.appendingPathComponent("restore.ipsw")
  try zipFixture(at: url, members: members)
  let result = try RestoreInspection.inspect(url)
  #expect(result.componentPaths.count == profile.requiredComponents.count)
  #expect(result.metadataSHA256["BuildManifest.plist"] == SafeFile.sha256(manifest))
  #expect(!result.vmStarted && result.preflightOnly && !result.payloadsAuthenticated)
  #expect(throws: (any Error).self) { try RestoreInspection.inspect(url, verifyDigest: true) }
}

@Test func zipReadExtractAndLimits() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let url = directory.url.appendingPathComponent("archive.zip")
  let content = Data(repeating: 42, count: 1024)
  try zipFixture(at: url, members: [("member", content)])
  let reader = try IPSWArchive(url)
  #expect(try reader.read("member") == content)
  #expect(throws: (any Error).self) { try reader.read("member", limit: 1023) }
  #expect(throws: (any Error).self) { try reader.read("../member") }
  let output = directory.url.appendingPathComponent("output")
  let report = try reader.extract("member", to: output, expectedSHA256: SafeFile.sha256(content))
  #expect(report.bytes == 1024)
  #expect(try SafeFile.read(output, limit: 1024) == content)
  #expect(throws: (any Error).self) {
    try reader.extract("member", to: output, expectedSHA256: report.sha256)
  }
  #expect(throws: (any Error).self) {
    try reader.extract(
      "member", to: directory.url.appendingPathComponent("wrong"),
      expectedSHA256: String(repeating: "0", count: 64))
  }
}

@Test func zipRejectsDuplicateEncryptedAndCorruptEntries() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let duplicate = directory.url.appendingPathComponent("duplicate.zip")
  try zipFixture(at: duplicate, members: [("same", Data([1])), ("same", Data([2]))])
  #expect(throws: (any Error).self) { try IPSWArchive(duplicate) }
  let original = directory.url.appendingPathComponent("original.zip")
  try zipFixture(at: original, members: [("member", Data([1, 2, 3]))], compression: .none)
  let bytes = try SafeFile.read(original, limit: 1 << 20)
  let central = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))?.lowerBound)
  var encrypted = bytes
  encrypted.put(UInt16(1), at: central + 8)
  let encryptedURL = directory.url.appendingPathComponent("encrypted.zip")
  try SafeFile.writeNew(encrypted, to: encryptedURL)
  #expect(throws: (any Error).self) { try IPSWArchive(encryptedURL) }
  var corrupt = bytes
  corrupt[36] ^= 0xff
  let corruptURL = directory.url.appendingPathComponent("corrupt.zip")
  try SafeFile.writeNew(corrupt, to: corruptURL)
  #expect(throws: (any Error).self) { try IPSWArchive(corruptURL).read("member") }
  var device = bytes
  device.put(UInt32(0o020600) << 16, at: central + 38)
  let deviceURL = directory.url.appendingPathComponent("device.zip")
  try SafeFile.writeNew(device, to: deviceURL)
  #expect(throws: (any Error).self) { try IPSWArchive(deviceURL).read("member") }
}

@Test func zipExtractionRequiresPinnedDigestAndUnchangedInput() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("archive.zip")
  let content = Data("verified archive fixture".utf8)
  try zipFixture(at: source, members: [("member", content)])
  let output = directory.url.appendingPathComponent("output")
  #expect(throws: (any Error).self) { try IPSWArchive(source).extract("member", to: output) }
  #expect(!FileManager.default.fileExists(atPath: output.path))
  #expect(throws: (any Error).self) {
    try IPSWArchive(source, expectedSHA256: String(repeating: "0", count: 64))
  }
  let reader = try IPSWArchive(source, expectedSHA256: SafeFile.sha256(source))
  #expect(try reader.extract("member", to: output).sha256 == SafeFile.sha256(content))
  let replacement = directory.url.appendingPathComponent("replacement.zip")
  try zipFixture(at: replacement, members: [("member", Data("changed".utf8))])
  try FileManager.default.removeItem(at: source)
  try FileManager.default.moveItem(at: replacement, to: source)
  #expect(throws: (any Error).self) { try reader.read("member") }
}

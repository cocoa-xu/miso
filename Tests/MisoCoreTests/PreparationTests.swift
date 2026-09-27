import AppleArchive
import Foundation
import System
import Testing

@testable import MisoCore

private func canonicalFixture(_ url: URL, files: [(String, Data)]) throws {
  let handle = try SafeFile.create(url)
  defer { try? handle.close() }
  let stream = try #require(
    ArchiveByteStream.fileStream(
      fd: FileDescriptor(rawValue: handle.fileDescriptor), automaticClose: false))
  defer { try? stream.close() }
  let archive = try #require(ArchiveStream.encodeStream(writingTo: stream))
  defer { try? archive.close() }
  let root = ArchiveHeader()
  root.append(.uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.directory.rawValue)))
  root.append(.string(key: .init("PAT"), value: "."))
  try archive.writeHeader(root)
  for (name, bytes) in files {
    let header = ArchiveHeader()
    header.append(
      .uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
    header.append(.string(key: .init("PAT"), value: name))
    header.append(.blob(key: .init("DAT"), size: UInt64(bytes.count)))
    try archive.writeHeader(header)
    try bytes.withUnsafeBytes { try archive.writeBlob(key: .init("DAT"), from: $0) }
  }
  try archive.close()
  try stream.close()
}

@Test func nativeCanonicalMetadataExtraction() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let archive = directory.url.appendingPathComponent("canonical.aar")
  let output = directory.url.appendingPathComponent("canonical")
  let mtree = Data("# fixture\n. type=dir mode=755 time=1700000000.123456789\n".utf8)
  let digest = Data(repeating: 17, count: (2 << 20) + 9)
  try canonicalFixture(archive, files: [("mtree.txt", mtree), ("digest.db", digest)])
  try CanonicalMetadata.extract(archive, to: output)
  #expect(try SafeFile.read(output.appendingPathComponent("digest.db"), limit: 3 << 20) == digest)
  let remap = try CanonicalMetadata.timestampRemap(output.appendingPathComponent("mtree.txt"))
  #expect(remap.count == 5 && remap.values.allSatisfy { $0 == 1_700_000_000_123_456_789 })
}

@Test(arguments: ["../escaped", "unexpected", "mtree.txt"])
func canonicalMetadataRejectsUnexpectedAndDuplicateEntries(_ name: String) throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let archive = directory.url.appendingPathComponent("canonical.aar")
  try canonicalFixture(archive, files: [("mtree.txt", Data([1])), (name, Data([2]))])
  #expect(throws: (any Error).self) {
    try CanonicalMetadata.extract(archive, to: directory.url.appendingPathComponent("out"))
  }
  #expect(
    !FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("escaped").path))
}

@Test func streamingImage4Extraction() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("payload.im4p")
  let output = directory.url.appendingPathComponent("raw")
  let content = Data(repeating: 0x71, count: (3 << 20) + 41)
  let bytes = DER.encode(
    0x30,
    DER.encode(0x16, Data("IM4P".utf8)) + DER.encode(0x16, Data("test".utf8))
      + DER.encode(0x16, Data()) + DER.encode(4, content))
  try SafeFile.writeNew(bytes, to: source)
  let result = try Image4.unwrap(source: source, output: output)
  #expect(result.bytes == content.count && result.sha256 == SafeFile.sha256(content))
  #expect(try SafeFile.read(output, limit: 4 << 20) == content)
  #expect(throws: (any Error).self) {
    try Image4.unwrap(
      source: source, output: output.appendingPathExtension("small"), maximumBytes: 3 << 20)
  }
  let truncated = directory.url.appendingPathComponent("truncated.im4p")
  try SafeFile.writeNew(Data(bytes.dropLast()), to: truncated)
  #expect(throws: (any Error).self) {
    try Image4.unwrap(source: truncated, output: output.appendingPathExtension("truncated"))
  }
}

@Test func appleCodeSignatureValidation() throws {
  try AppleCode.validate(URL(fileURLWithPath: "/usr/bin/true"))
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let unsigned = directory.url.appendingPathComponent("unsigned")
  try SafeFile.writeNew(Data("not executable code".utf8), to: unsigned)
  #expect(throws: (any Error).self) { try AppleCode.validate(unsigned) }
}

@Test @MainActor func restoreInputsContainAdditionalIdentityComponents() throws {
  let profile = RestoreProfile.supported[0]
  var value = restoreMetadata(profile)
  var identities = value.manifest["BuildIdentities"] as! [[String: Any]]
  var manifest = identities[0]["Manifest"] as! [String: Any]
  manifest["AdditionalComponent"] = ["Info": ["Path": "additional.bin"]]
  identities[0]["Manifest"] = manifest
  value.manifest["BuildIdentities"] = identities
  let inspected = try RestoreInspection.select(manifest: value.manifest, restore: value.restore)
  #expect(inspected.componentPaths["AdditionalComponent"] == "additional.bin")
  let paths = try RestorePreparation.inputPaths(inspected)
  #expect(paths.contains("additional.bin"))
  #expect(paths.contains("usr/standalone/bootcaches.plist"))
  #expect(paths.contains(RestorePreparation.ticketPath(profile, cryptex: true)))
}

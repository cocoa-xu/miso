import Foundation
import Testing

@testable import MisoCore

@Test func flutterStableSelectionRequiresOneMatchingReleaseTag() throws {
  let commit = String(repeating: "a", count: 40)
  let record = ImageBundle.FileRecord(
    path: "input", bytes: 1, sha256: String(repeating: "0", count: 64))
  let source = GitSnapshot.Receipt(
    schemaVersion: 1, repository: "flutter/flutter",
    selection: .init(reference: "refs/heads/stable", objectID: commit, commitID: commit),
    capabilities: record, advertisement: record, response: record)
  let capabilities =
    try GitRemote.packet("version 2\n") + GitRemote.packet("ls-refs\n")
    + GitRemote.packet("fetch=shallow\n") + Data("0000".utf8)
  func tags(_ values: [(String, String)]) throws -> Data {
    try values.reduce(Data()) { try $0 + GitRemote.packet("\($1.0) refs/tags/\($1.1)\n") }
      + Data("0000".utf8)
  }
  #expect(
    try XcodeFlutterInputs.stableVersion(
      source: source, capabilities: capabilities, tags: tags([(commit, "3.47.6")])) == "3.47.6")
  for values in [
    [(commit, "3.47.6-beta")], [(String(repeating: "b", count: 40), "3.47.6")],
    [(commit, "3.47.6"), (commit, "3.47.7")],
  ] {
    #expect(throws: MisoError.self) {
      try XcodeFlutterInputs.stableVersion(
        source: source, capabilities: capabilities, tags: tags(values))
    }
  }
}

@Test func flutterDartMetadataBindsEngineSizeAndDigest() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let engine = String(repeating: "a", count: 40)
  let object = XcodeFlutterInputs.DartObject(
    name: "flutter/" + engine + "/dart-sdk-darwin-arm64.zip", size: "3",
    md5Hash: "kAFQmDzST7DWlj99KOF/cg==", generation: "1")
  #expect(try object.validate(engine: engine) == 3)
  #expect(throws: MisoError.self) { try object.validate(engine: String(repeating: "b", count: 40)) }
  let archive = temporary.url.appendingPathComponent("dart.zip")
  let metadata = temporary.url.appendingPathComponent("object.json")
  try SafeFile.writeNew(Data("abc".utf8), to: archive)
  try SafeFile.writeNew(JSON.encode(object), to: metadata)
  try XcodeFlutterInputs.validateDart(
    archive, metadata: metadata, engine: engine, cancellation: nil)
  try SafeFile.replace(Data("bad".utf8), at: archive)
  #expect(throws: MisoError.self) {
    try XcodeFlutterInputs.validateDart(
      archive, metadata: metadata, engine: engine, cancellation: nil)
  }
  for (size, hash, generation) in [
    ("0", object.md5Hash, "1"), ("536870913", object.md5Hash, "1"), ("3", "bad", "1"),
    ("3", object.md5Hash, "bad"),
  ] {
    #expect(throws: MisoError.self) {
      try XcodeFlutterInputs.DartObject(
        name: object.name, size: size, md5Hash: hash, generation: generation
      ).validate(engine: engine)
    }
  }
}

@Test func flutterProfilePreservesExistingConfigurationAndAvoidsDuplicatePaths() throws {
  let original = Data("export OTHER=preserved".utf8)
  let updated = try XcodeFlutterInstallation.shellProfile(original)
  #expect(String(decoding: updated, as: UTF8.self).hasPrefix("export OTHER=preserved\n"))
  #expect(
    String(decoding: updated, as: UTF8.self).contains(#"export PUB_CACHE="$HOME/.pub-cache""#))
  #expect(try XcodeFlutterInstallation.shellProfile(updated) == updated)
  #expect(throws: MisoError.self) {
    try XcodeFlutterInstallation.shellProfile(Data([0]))
  }
}

@Test func flutterReplayRejectsTrackedSourceAndGitConfigurationChanges() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let source = temporary.url.appendingPathComponent("source/checkout")
  try SafeFile.makeDirectory(source.deletingLastPathComponent())
  try SafeFile.makeDirectory(source)
  try SafeFile.makeDirectory(source.appendingPathComponent(".git"))
  for path in [".gitignore", "source.dart", ".git/config", ".git/shallow"] {
    try SafeFile.writeNew(Data("source".utf8), to: source.appendingPathComponent(path))
  }
  let flutter = temporary.url.appendingPathComponent("flutter")
  try FileManager.default.copyItem(at: source, to: flutter)
  try XcodeFlutterInputs.verifySource(output: temporary.url, cancellation: nil)
  for path in [".gitignore", "source.dart", ".git/config"] {
    try SafeFile.replace(Data("changed".utf8), at: flutter.appendingPathComponent(path))
    #expect(throws: MisoError.self) {
      try XcodeFlutterInputs.verifySource(output: temporary.url, cancellation: nil)
    }
    try SafeFile.replace(Data("source".utf8), at: flutter.appendingPathComponent(path))
  }
}

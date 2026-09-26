import Foundation
import Testing

@testable import MisoCore

@Test(arguments: ["15", "015.6", "15.06", "15.6.01", "15.6.1.2", "15.6\n", "-1.0", "15.x"])
func invalidVersions(_ value: String) {
  #expect(throws: (any Error).self) { try MacOSVersion(value) }
}

@Test func versionOrdering() throws {
  #expect(try MacOSVersion("15.8") == MacOSVersion("15.8.0"))
  #expect(try MacOSVersion("15.7.9") < MacOSVersion("15.8"))
  try MacOSVersion.requireUpgrade(from: "15.6.1", to: "15.8")
  #expect(throws: (any Error).self) { try MacOSVersion.requireUpgrade(from: "15.8", to: "26.7") }
  #expect(throws: (any Error).self) { try MacOSVersion.requireUpgrade(from: "26.7", to: "26.6.2") }
}

@Test func exactProfiles() throws {
  #expect(RestoreProfile.supported.count == 3)
  #expect(UpgradeProfile.supported.count == 5)
  for profile in RestoreProfile.supported {
    #expect(try RestoreProfile.select(profile.release) == profile)
    try SafeFile.validateSHA256(profile.ipswSHA256)
  }
  for profile in UpgradeProfile.supported {
    #expect(try UpgradeProfile.select(source: profile.source, target: profile.target) == profile)
    #expect(throws: (any Error).self) {
      try UpgradeProfile.select(
        source: profile.source, target: .init(version: profile.target.version, build: "wrong"))
    }
  }
  #expect(throws: (any Error).self) {
    try RestoreProfile.select(.init(version: "26.1", build: "unknown"))
  }
}

@Test(arguments: ["", "/etc/passwd", "../a", "a/../b", "a//b", "a/", "./a", "a\\b", "a\0b"])
func unsafePaths(_ path: String) {
  #expect(throws: (any Error).self) { try SafeFile.relativePath(path) }
}

@Test func configurationValidation() throws {
  var config = ImageConfiguration()
  try config.validate()
  #expect(!config.installRosetta && !config.includeLinuxTranslation && !config.filevault)
  config.filevault = true
  #expect(throws: (any Error).self) { try config.validate() }
  config.filevault = false
  config.username = "root"
  #expect(throws: (any Error).self) { try config.validate() }
  config.username = "admin"
  config.timeZone = "../Tokyo"
  #expect(throws: (any Error).self) { try config.validate() }
}

@Test func templateActions() throws {
  func entry(_ value: String) -> [String: JSONValue] {
    ["flags": .integer(0), "xattrs": .object([:]), "sha256": .string(value)]
  }
  let old = [
    "replace": entry("a"), "remove": entry("a"), "deleted": entry("a"), "current": entry("a"),
    "conflict": entry("a"),
  ]
  let new = [
    "replace": entry("b"), "add": entry("b"), "deleted": entry("b"), "current": entry("b"),
    "conflict": entry("b"),
  ]
  let current = [
    "replace": entry("a"), "remove": entry("a"), "current": entry("b"), "conflict": entry("c"),
  ]
  let actions = try TemplateUpgrade.plan(old: old, new: new, current: current)
  #expect(
    actions.map(\.action) == [
      .add, .conflictModified, .alreadyCurrent, .preserveDeletion, .remove, .replace,
    ])
  #expect(throws: (any Error).self) { try TemplateUpgrade.requireUnambiguous(actions) }
  try TemplateUpgrade.requireUnambiguous(actions.filter { !$0.isConflict })
}

@Test func compressionNormalization() throws {
  let raw: [String: JSONValue] = [
    "flags": .integer(0), "xattrs": .object([:]), "sha256": .string("a"),
  ]
  var compressed = raw
  compressed["flags"] = .integer(32)
  compressed["inode"] = .integer(123)
  compressed["xattrs"] = .object([
    "com.apple.decmpfs": .string("ignored"), "com.apple.ResourceFork": .string("ignored"),
  ])
  #expect(try TemplateUpgrade.normalize(raw) == TemplateUpgrade.normalize(compressed))
  compressed["flags"] = .integer(0)
  #expect(try TemplateUpgrade.normalize(raw) != TemplateUpgrade.normalize(compressed))
}

@Test func fileSafety() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent(UUID().uuidString)
  try SafeFile.makeDirectory(root)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("file")
  try SafeFile.writeNew(Data("hello".utf8), to: file)
  #expect(throws: (any Error).self) { try SafeFile.writeNew(Data(), to: file) }
  #expect(throws: (any Error).self) { try SafeFile.read(file, limit: 4) }
  let link = root.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
  #expect(throws: (any Error).self) { try SafeFile.read(link, limit: 100) }
  #expect(
    try SafeFile.sha256(file) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

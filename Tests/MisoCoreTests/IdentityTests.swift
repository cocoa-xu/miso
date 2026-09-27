import Foundation
import Testing

@testable import MisoCore

@Test(arguments: ["disk11s8", "rdisk11s8", "/dev/disk11s8", "/dev/rdisk11s8"])
func rawDeviceNormalization(_ input: String) throws {
  #expect(try APFSIdentity.rawVolume(input) == "/dev/rdisk11s8")
}

@Test(arguments: ["disk0", "/dev/disk0", "disk1s2\n", "/dev/../disk1s2", "disk1s2s3", "disk１s２"])
func rejectAmbiguousDevices(_ input: String) {
  #expect(throws: (any Error).self) { try APFSIdentity.rawVolume(input) }
}

@Test func snapshotPolicyPreserved() throws {
  let old: [String: JSONValue] = [
    "SnapshotName": .string("com.apple.os.update-test"), "SnapshotUUID": .string("uuid"),
    "RootTo": .bool(true), "Purgeable": .bool(false), "SnapshotXID": .integer(42),
    "LimitingContainerShrink": .bool(false),
  ]
  var new = old
  new["LimitingContainerShrink"] = .bool(true)
  #expect(try APFSIdentity.verifySnapshots(before: [old], after: [new]).count == 1)
  new["LimitingContainerShrink"] = .integer(1)
  #expect(throws: (any Error).self) {
    try APFSIdentity.verifySnapshots(before: [old], after: [new])
  }
  for field in ["RootTo", "Purgeable", "SnapshotXID", "SnapshotUUID", "unknown"] {
    new = old
    new[field] = .null
    #expect(throws: (any Error).self) {
      try APFSIdentity.verifySnapshots(before: [old], after: [new])
    }
  }
}

@Test func systemUUIDMayRotateButDataMustNot() throws {
  let system = try APFSIdentity.Volume(device: "disk11s1", identifier: UUID(), roles: ["System"])
  let updated = try APFSIdentity.Volume(device: "disk11s1", identifier: UUID(), roles: ["System"])
  let data = try APFSIdentity.Volume(device: "disk11s2", identifier: UUID(), roles: ["Data"])
  let container = UUID()
  let before = try APFSIdentity.Container(identifier: container, volumes: [system, data])
  let after = try APFSIdentity.Container(identifier: container, volumes: [updated, data])
  #expect(try APFSIdentity.resealedSystem(before: before, after: after, system: system) == updated)
  let changedData = try APFSIdentity.Volume(
    device: data.device, identifier: UUID(), roles: data.roles)
  let corrupted = try APFSIdentity.Container(
    identifier: container, volumes: [updated, changedData])
  #expect(throws: (any Error).self) {
    try APFSIdentity.resealedSystem(before: before, after: corrupted, system: system)
  }
  #expect(throws: (any Error).self) {
    try APFSIdentity.Container(identifier: container, volumes: [system, system])
  }
}

@Test func bundleVerificationAndNegativeControl() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let content = Data("fixture".utf8)
  let files = ImageBundle.requiredFiles.sorted().map {
    ImageBundle.FileRecord(path: $0, bytes: UInt64(content.count), sha256: SafeFile.sha256(content))
  }
  for file in files {
    try SafeFile.writeNew(content, to: directory.url.appendingPathComponent(file.path))
  }
  struct Manifest: Encodable {
    let schemaVersion = 1
    let files: [ImageBundle.FileRecord]
    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case files
    }
  }
  try SafeFile.writeNew(
    JSON.encode(Manifest(files: files)), to: directory.url.appendingPathComponent("manifest.json"))
  #expect(try ImageBundle.verify(directory.url).files == files)
  let changed = directory.url.appendingPathComponent("aux.bin")
  let handle = try FileHandle(forWritingTo: changed)
  try handle.write(contentsOf: Data("changed".utf8))
  try handle.close()
  #expect(throws: (any Error).self) { try ImageBundle.verify(directory.url) }
}

@Test func bundleManifestRejectsTraversalAndDuplicates() throws {
  let record = ImageBundle.FileRecord(
    path: "../outside", bytes: 1, sha256: String(repeating: "0", count: 64))
  #expect(throws: (any Error).self) {
    try ImageBundle.Manifest(schemaVersion: 1, files: [record]).validate()
  }
  let duplicates = Array(
    repeating: ImageBundle.FileRecord(
      path: "disk.img", bytes: 1, sha256: String(repeating: "0", count: 64)), count: 4)
  #expect(throws: (any Error).self) {
    try ImageBundle.Manifest(schemaVersion: 1, files: duplicates).validate()
  }
}

import Foundation
import Testing

@testable import MisoCore

@Test func sealedSystemReattachmentRequiresStableIdentities() throws {
  let container = UUID()
  let volume = UUID()
  func topology(_ device: String, id: UUID = UUID(), volumeID: UUID) -> APFSTopology.Container {
    .init(
      device: device, identifier: id, stores: [.init(device: "disk10s2")],
      volumes: [
        .init(
          device: device + "s1", identifier: volumeID, roles: ["System"], name: "System",
          mountPoint: nil)
      ])
  }
  let reattached = topology("disk12", id: container, volumeID: volume)
  let selected = try SystemConstruction.systemVolume(
    in: [reattached], container: container, volume: volume)
  #expect(selected.device == "disk12s1")
  for invalid in [
    [], [reattached, reattached], [topology("disk12", volumeID: volume)],
    [topology("disk12", id: container, volumeID: UUID())],
    [
      APFSTopology.Container(
        device: "disk12", identifier: container, stores: reattached.stores,
        volumes: reattached.volumes + reattached.volumes)
    ],
  ] {
    #expect(throws: (any Error).self) {
      try SystemConstruction.systemVolume(in: invalid, container: container, volume: volume)
    }
  }
}

@Test func systemReceiptRequiresExactSealAndRootSnapshot() throws {
  let volume = UUID()
  let container = UUID()
  let snapshot = UUID()
  let name = "com.apple.os.update-fixture"
  let info = SystemConstruction.VolumeInfo(identifier: volume, sealed: "Yes")
  let root = SystemConstruction.Snapshots.Snapshot(identifier: snapshot, name: name, root: true)
  let snapshots = SystemConstruction.Snapshots(snapshots: [root])
  let receipt = try SystemConstruction.verify(
    info: info, snapshots: snapshots, container: container, volume: volume, expectedName: name)
  #expect(receipt.snapshot == snapshot && receipt.container == container)
  for invalid in [
    SystemConstruction.VolumeInfo(identifier: volume, sealed: "No"),
    SystemConstruction.VolumeInfo(identifier: UUID(), sealed: "Yes"),
  ] {
    #expect(throws: (any Error).self) {
      try SystemConstruction.verify(
        info: invalid, snapshots: snapshots, container: container, volume: volume,
        expectedName: name)
    }
  }
  #expect(throws: (any Error).self) {
    try SystemConstruction.verify(
      info: info, snapshots: .init(snapshots: [root, root]), container: container, volume: volume,
      expectedName: name)
  }
  #expect(throws: (any Error).self) {
    try SystemConstruction.verify(
      info: info, snapshots: snapshots, container: container, volume: volume, expectedName: "wrong")
  }
}

@Test func preparedArtifactResolutionRejectsChangesAndEscapes() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let path = directory.url.appendingPathComponent("input")
  try SafeFile.writeNew(Data([1, 2, 3]), to: path)
  let record = try Artifacts.record(path, relativeTo: directory.url)
  #expect(try Artifacts.resolve(record, under: directory.url) == path)
  for invalid in [
    ImageBundle.FileRecord(path: "../input", bytes: record.bytes, sha256: record.sha256),
    ImageBundle.FileRecord(path: "input", bytes: 99, sha256: record.sha256),
    ImageBundle.FileRecord(
      path: "input", bytes: record.bytes, sha256: String(repeating: "0", count: 64)),
  ] {
    #expect(throws: (any Error).self) { try Artifacts.resolve(invalid, under: directory.url) }
  }
  let link = directory.url.appendingPathComponent("linked")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
  #expect(throws: (any Error).self) {
    try Artifacts.resolve(
      .init(path: "linked", bytes: record.bytes, sha256: record.sha256), under: directory.url)
  }
}

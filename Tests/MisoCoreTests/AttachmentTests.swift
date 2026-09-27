import Foundation
import Testing

@testable import MisoCore

@Test(arguments: [(11, 12), (28, 31), (407, 519)])
func topologyRejectsForeignAndMixedStores(_ disks: (Int, Int)) throws {
  let physical = "disk\(disks.0)"
  let container = "disk\(disks.1)"
  let attachment = DiskImageAttachment(entities: [
    .init(device: "/dev/\(physical)", contentHint: "GUID_partition_scheme", mountPoint: nil),
    .init(device: "/dev/\(physical)s2", contentHint: "Apple_APFS", mountPoint: nil),
  ])
  #expect(try attachment.wholeDevice(requireGPT: true) == "/dev/\(physical)")
  let own = APFSTopology.Container(
    device: container, identifier: UUID(), stores: [.init(device: "\(physical)s2")],
    volumes: [
      .init(
        device: "\(container)s1", identifier: UUID(), roles: ["System"], name: "System",
        mountPoint: nil)
    ])
  let foreign = APFSTopology.Container(
    device: "disk3", identifier: UUID(), stores: [.init(device: "disk0s2")], volumes: [])
  let matched = try APFSTopology(containers: [foreign, own]).owned(by: attachment)
  #expect(matched.count == 1 && matched[0].identifier == own.identifier)
  let mixed = APFSTopology.Container(
    device: container, identifier: UUID(),
    stores: [.init(device: "\(physical)s2"), .init(device: "disk0s2")], volumes: [])
  #expect(throws: (any Error).self) { try APFSTopology(containers: [mixed]).owned(by: attachment) }
  #expect(throws: (any Error).self) {
    try APFSTopology(containers: [own, own]).owned(by: attachment)
  }
}

@Test func writableAttachmentRequiresOperationOwnership() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let outside = directory.url.appendingPathComponent("outside.img")
  try SafeFile.writeNew(Data([0]), to: outside)
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("work"), operation: "attachment")
  #expect(throws: (any Error).self) {
    try DiskImageSession(image: outside, readOnly: false, journal: journal)
  }
  let readOnly = try DiskImageSession(image: outside, readOnly: true, journal: journal)
  #expect(readOnly.readOnly)
  #expect(throws: (any Error).self) {
    try DiskImageSession(
      image: outside, readOnly: true, journal: journal, forceReadOnlyDetach: true)
  }
  let owned = journal.output.appendingPathComponent("owned.img")
  try SafeFile.writeNew(Data([0]), to: owned)
  #expect(throws: (any Error).self) {
    try DiskImageSession(image: owned, readOnly: false, journal: journal, forceReadOnlyDetach: true)
  }
  _ = try DiskImageSession(
    image: owned, readOnly: true, journal: journal, forceReadOnlyDetach: true)
  let escaped = URL(fileURLWithPath: journal.output.path + "/../outside.img")
  #expect(throws: (any Error).self) {
    try DiskImageSession(image: escaped, readOnly: false, journal: journal)
  }
  let link = journal.output.appendingPathComponent("linked.img")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
  #expect(throws: (any Error).self) {
    try DiskImageSession(image: link, readOnly: false, journal: journal)
  }
}

@Test func wholeDeviceSelectionRejectsAmbiguityAndInvalidNodes() throws {
  let entity = DiskImageAttachment.Entity(
    device: "/dev/disk11", contentHint: "GUID_partition_scheme", mountPoint: nil)
  #expect(throws: (any Error).self) {
    try DiskImageAttachment(entities: [entity, entity]).wholeDevice(requireGPT: true)
  }
  #expect(throws: (any Error).self) {
    try DiskImageAttachment(entities: [
      entity, .init(device: "/dev/disk0;bad", contentHint: nil, mountPoint: nil),
    ]).wholeDevice(requireGPT: true)
  }
}

@Test func rawImageSelectionExcludesSynthesizedAPFSContainer() throws {
  let attachment = DiskImageAttachment(entities: [
    .init(device: "/dev/disk42", contentHint: nil, mountPoint: nil),
    .init(
      device: "/dev/disk57", contentHint: "EF57347C-0000-11AA-AA11-00306543ECAC", mountPoint: nil),
    .init(
      device: "/dev/disk57s1", contentHint: "41504653-0000-11AA-AA11-00306543ECAC", mountPoint: nil),
  ])
  #expect(try attachment.wholeDevice(requireGPT: false) == "/dev/disk42")
  #expect(throws: (any Error).self) { try attachment.wholeDevice(requireGPT: true) }
}

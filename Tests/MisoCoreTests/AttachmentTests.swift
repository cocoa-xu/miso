import Foundation
import Testing

@testable import MisoCore

private func imageInventory(_ images: [[String: Any]]) throws -> Data {
  try PropertyListSerialization.data(
    fromPropertyList: ["images": images], format: .xml, options: 0)
}

@Test func imageInventoryIgnoresIncompleteForeignAttachments() throws {
  let path = "/work/owned.img"
  let owned: [String: Any] = [
    "image-path": path, "writeable": false,
    "system-entities": [["dev-entry": "/dev/disk11", "content-hint": "GUID_partition_scheme"]],
  ]
  let foreign: [String: Any] = [
    "image-path": "/other/build.img",
    "system-entities": [
      ["dev-entry": "/dev/disk12"], ["dev-entry": "/dev/disk12s1"],
      ["content-hint": "Apple_APFS"],
    ],
  ]
  let data = try imageInventory([owned, foreign])
  let matches = try DiskImageSession.ImageInfo.matching(data, path: path)
  #expect(matches.count == 1)
  #expect(matches.first?.writable == false)
  #expect(matches.first?.entities.map(\.device) == ["/dev/disk11"])
  #expect(try DiskImageSession.ImageInfo.matching(data, path: "/work/detached.img").isEmpty)
}

@Test func imageInventoryStillRejectsIncompleteOwnedAttachments() throws {
  let path = "/work/owned.img"
  let data = try imageInventory([
    ["image-path": path, "writeable": true, "system-entities": [["content-hint": "Apple_APFS"]]]
  ])
  #expect(throws: DecodingError.self) {
    try DiskImageSession.ImageInfo.matching(data, path: path)
  }
}

@Test func imageInventoryPreservesDuplicateOwnershipForRejection() throws {
  let path = "/work/owned.img"
  let image: [String: Any] = [
    "image-path": path, "writeable": true, "system-entities": [["dev-entry": "/dev/disk11"]],
  ]
  let matches = try DiskImageSession.ImageInfo.matching(
    imageInventory([image, image]), path: path)
  #expect(matches.count == 2)
}

@Test func imageInventoryDoesNotMatchPathPrefixesOrMissingPaths() throws {
  let data = try imageInventory([
    [
      "image-path": "/work/owned.img.other", "system-entities": [["mount-point": "/Volumes/Other"]],
    ],
    ["system-entities": [["dev-entry": "/dev/disk11"]]],
  ])
  #expect(try DiskImageSession.ImageInfo.matching(data, path: "/work/owned.img").isEmpty)
}

@Test func imageInventoryRejectsMalformedEnvelope() throws {
  let data = try PropertyListSerialization.data(
    fromPropertyList: ["images": "invalid"], format: .binary, options: 0)
  #expect(throws: (any Error).self) {
    try DiskImageSession.ImageInfo.matching(data, path: "/work/owned.img")
  }
}

@Test func imageOwnershipWaitsForMissingInventoryAndWholeDevice() throws {
  let owned = DiskImageSession.ImageInfo.Image(
    path: "/work/owned.img",
    entities: [.init(device: "/dev/disk11", contentHint: nil, mountPoint: nil)], writable: true)
  let incomplete = DiskImageSession.ImageInfo.Image(
    path: owned.path, entities: [], writable: true)
  var queries = 0
  var pauses = 0
  let result = try DiskImageSession.ImageInfo.owned(
    path: "/work/owned.img", device: "/dev/disk11", readOnly: false,
    refresh: {
      queries += 1
      return queries == 1 ? [] : [queries == 2 ? incomplete : owned]
    }, pause: { pauses += 1 })
  #expect(result.entities.map(\.device) == ["/dev/disk11"])
  #expect(queries == 3 && pauses == 2)
}

@Test func imageOwnershipRejectsAmbiguousOrChangedAccessImmediately() {
  let owned = DiskImageSession.ImageInfo.Image(
    path: "/work/owned.img",
    entities: [.init(device: "/dev/disk11", contentHint: nil, mountPoint: nil)], writable: true)
  let readOnly = DiskImageSession.ImageInfo.Image(
    path: owned.path, entities: owned.entities, writable: false)
  let unknown = DiskImageSession.ImageInfo.Image(
    path: owned.path, entities: owned.entities, writable: nil)
  for matches in [[owned, owned], [readOnly], [unknown]] {
    var queries = 0
    #expect(throws: (any Error).self) {
      try DiskImageSession.ImageInfo.owned(
        path: "/work/owned.img", device: "/dev/disk11", readOnly: false,
        refresh: {
          queries += 1
          return matches
        },
        pause: { Issue.record("Conflicting ownership must not be retried") })
    }
    #expect(queries == 1)
  }
}

@Test func imageOwnershipWaitIsBoundedAndNeverAcceptsAnotherDevice() {
  let foreign = DiskImageSession.ImageInfo.Image(
    path: "/work/owned.img",
    entities: [.init(device: "/dev/disk12", contentHint: nil, mountPoint: nil)], writable: true)
  for matches in [[], [foreign]] {
    var queries = 0
    var pauses = 0
    do {
      _ = try DiskImageSession.ImageInfo.owned(
        path: "/work/owned.img", device: "/dev/disk11", readOnly: false,
        refresh: {
          queries += 1
          return matches
        }, pause: { pauses += 1 })
      Issue.record("Missing attachment ownership was accepted")
    } catch {
      #expect(error.localizedDescription.contains("/work/owned.img"))
      #expect(error.localizedDescription.contains("expected /dev/disk11"))
      #expect(error.localizedDescription.contains("observed \(matches.count) matching images"))
      if !matches.isEmpty { #expect(error.localizedDescription.contains("/dev/disk12")) }
    }
    #expect(queries == 10 && pauses == 9)
  }
}

@Test func imageOwnershipDoesNotRetryCommandOrFileIdentityErrors() {
  var queries = 0
  #expect(throws: (any Error).self) {
    try DiskImageSession.ImageInfo.owned(
      path: "/work/owned.img", device: "/dev/disk11", readOnly: true,
      refresh: {
        queries += 1
        throw MisoError.invalid("Image file identity changed")
      },
      pause: { Issue.record("Invalid image identity must not be retried") })
  }
  #expect(queries == 1)
}

@Test func detachmentWaitAllowsStaleAndIncompleteInventory() throws {
  let stale = DiskImageSession.ImageInfo.Image(
    path: "/work/owned.img",
    entities: [.init(device: "/dev/disk11", contentHint: nil, mountPoint: nil)], writable: false)
  let incomplete = DiskImageSession.ImageInfo.Image(
    path: stale.path, entities: [], writable: nil)
  var queries = 0
  var pauses = 0
  try DiskImageSession.ImageInfo.waitUntilDetached(
    path: "/work/owned.img",
    refresh: {
      queries += 1
      return queries < 3 ? [queries == 1 ? stale : incomplete] : []
    }, pause: { pauses += 1 })
  #expect(queries == 3 && pauses == 2)
}

@Test func detachmentWaitNeverAcceptsRemainingAttachments() {
  let remaining = DiskImageSession.ImageInfo.Image(
    path: "/work/owned.img",
    entities: [.init(device: "/dev/disk12", contentHint: nil, mountPoint: nil)], writable: true)
  for matches in [[remaining], [remaining, remaining]] {
    var queries = 0
    var pauses = 0
    do {
      try DiskImageSession.ImageInfo.waitUntilDetached(
        path: "/work/owned.img",
        refresh: {
          queries += 1
          return matches
        }, pause: { pauses += 1 })
      Issue.record("A remaining attachment was accepted as detached")
    } catch {
      #expect(error.localizedDescription.contains("/work/owned.img"))
      #expect(error.localizedDescription.contains("/dev/disk12"))
      #expect(error.localizedDescription.contains("\(matches.count) matching images"))
    }
    #expect(queries == 10 && pauses == 9)
  }
}

@Test func detachmentWaitPropagatesInventoryErrors() {
  var queries = 0
  #expect(throws: (any Error).self) {
    try DiskImageSession.ImageInfo.waitUntilDetached(
      path: "/work/owned.img",
      refresh: {
        queries += 1
        throw MisoError.invalid("Image file identity changed")
      }, pause: { Issue.record("Invalid image identity must not be retried") })
  }
  #expect(queries == 1)
}

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

import Foundation
import Testing

@testable import MisoCore

private func volumeFixture() -> APFSTopology.Volume {
  .init(
    device: "disk42s2", identifier: UUID(), roles: ["Data"], name: "Data", mountPoint: nil)
}

@Test func mountMetadataCanLagSuccessfulNativeMount() throws {
  let volume = volumeFixture()
  var queries = 0
  try ImageMounts.waitForAttachment(
    volume: volume, mountPoint: "/fixture/Data",
    refresh: {
      queries += 1
      return DiskImageAttachment(
        entities: queries == 1
          ? []
          : [
            .init(
              device: "/dev/" + volume.device, contentHint: nil,
              mountPoint: queries == 2 ? nil : "/fixture/Data")
          ])
    }, pause: {})
  #expect(queries == 3)
}

@Test func mountMetadataWaitRejectsForeignAndAmbiguousMounts() {
  let volume = volumeFixture()
  let foreign = DiskImageAttachment.Entity(
    device: "/dev/" + volume.device, contentHint: nil, mountPoint: "/foreign/Data")
  for entries in [[foreign], [foreign, foreign]] {
    var queries = 0
    #expect(throws: (any Error).self) {
      try ImageMounts.waitForAttachment(
        volume: volume, mountPoint: "/fixture/Data",
        refresh: {
          queries += 1
          return DiskImageAttachment(entities: entries)
        }, pause: {})
    }
    #expect(queries == 1)
  }
}

@Test func mountMetadataWaitIsBoundedAndExplainsFailure() {
  var queries = 0
  do {
    try ImageMounts.waitForAttachment(
      volume: volumeFixture(), mountPoint: "/fixture/Data",
      refresh: {
        queries += 1
        return DiskImageAttachment(entities: [])
      }, pause: {})
    Issue.record("Missing mount metadata was accepted")
  } catch {
    #expect(error.localizedDescription.contains("disk42s2"))
    #expect(error.localizedDescription.contains("/fixture/Data"))
    #expect(error.localizedDescription.contains("0 entries"))
  }
  #expect(queries == 10)
}

@Test func mountMetadataWaitPropagatesAttachmentOwnershipFailure() {
  var queries = 0
  #expect(throws: (any Error).self) {
    try ImageMounts.waitForAttachment(
      volume: volumeFixture(), mountPoint: "/fixture/Data",
      refresh: {
        queries += 1
        throw MisoError.invalid("Changed attachment owner")
      }, pause: {})
  }
  #expect(queries == 1)
}

@Test func ownedVolumeRefreshRecoversOnlyMissingEntries() throws {
  let volume = volumeFixture()
  let entity = DiskImageAttachment.Entity(
    device: "/dev/" + volume.device, contentHint: nil, mountPoint: "/fixture/Data")
  var queries = 0
  var pauses = 0
  let result = try ImageMountGroup.ownedVolume(
    volume,
    refresh: {
      queries += 1
      return DiskImageAttachment(entities: queries == 1 ? [] : [entity])
    }, pause: { pauses += 1 })
  #expect(queries == 2 && pauses == 1)
  #expect(result.device == entity.device && result.mountPoint == entity.mountPoint)
}

@Test func ownedVolumeRefreshIsBounded() {
  var queries = 0
  var pauses = 0
  #expect(throws: (any Error).self) {
    try ImageMountGroup.ownedVolume(
      volumeFixture(),
      refresh: {
        queries += 1
        return DiskImageAttachment(entities: [])
      }, pause: { pauses += 1 })
  }
  #expect(queries == 3 && pauses == 2)
}

@Test func ownedVolumeRefreshRejectsAmbiguityImmediately() {
  let volume = volumeFixture()
  let entity = DiskImageAttachment.Entity(
    device: "/dev/" + volume.device, contentHint: nil, mountPoint: nil)
  var queries = 0
  var pauses = 0
  #expect(throws: (any Error).self) {
    try ImageMountGroup.ownedVolume(
      volume,
      refresh: {
        queries += 1
        return DiskImageAttachment(entities: [entity, entity])
      }, pause: { pauses += 1 })
  }
  #expect(queries == 1 && pauses == 0)
}

@Test func ownedVolumeRefreshPropagatesOwnershipFailure() {
  var queries = 0
  var pauses = 0
  #expect(throws: (any Error).self) {
    try ImageMountGroup.ownedVolume(
      volumeFixture(),
      refresh: {
        queries += 1
        throw MisoError.invalid("Changed attachment owner")
      }, pause: { pauses += 1 })
  }
  #expect(queries == 1 && pauses == 0)
}

@Test func ownedVolumeRefreshRejectsMissingImageImmediately() {
  var queries = 0
  var pauses = 0
  #expect(throws: (any Error).self) {
    try ImageMountGroup.ownedVolume(
      volumeFixture(),
      refresh: {
        queries += 1
        return nil
      }, pause: { pauses += 1 })
  }
  #expect(queries == 1 && pauses == 0)
}

@Test func ownedVolumeRefreshPreservesMountPointValidation() throws {
  let volume = volumeFixture()
  let attachment = DiskImageAttachment(entities: [
    .init(device: "/dev/" + volume.device, contentHint: nil, mountPoint: "/foreign/Data")
  ])
  let entry = try ImageMountGroup.ownedVolume(volume, refresh: { attachment })
  #expect(entry.mountPoint == "/foreign/Data")
  #expect(throws: (any Error).self) {
    try ImageMounts.verifyAttachment(attachment, volume: volume, mountPoint: "/fixture/Data")
  }
}

import Foundation
import Testing

@testable import MisoCore

private func volumeFixture() -> APFSTopology.Volume {
  .init(
    device: "disk42s2", identifier: UUID(), roles: ["Data"], name: "Data", mountPoint: nil)
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

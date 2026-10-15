import Darwin
import Foundation
import Testing

@testable import MisoCore

private func volumeFixture() -> APFSTopology.Volume {
  .init(
    device: "disk42s2", identifier: UUID(), roles: ["Data"], name: "Data", mountPoint: nil)
}

@Test func unmountedOwnedVolumeDoesNotNeedAnHDIEntity() throws {
  let volume = volumeFixture()
  let attachment = DiskImageAttachment(entities: [
    .init(device: "/dev/disk41s2", contentHint: "Apple_APFS", mountPoint: nil)
  ])
  let container = APFSTopology.Container(
    device: "disk42", identifier: UUID(), stores: [.init(device: "disk41s2")], volumes: [volume])
  let owned = try APFSTopology(containers: [container]).owned(by: attachment)
  #expect(owned.flatMap(\.volumes).map(\.identifier) == [volume.identifier])
  try ImageMounts.verifyMounts([], volume: volume, mountPoint: nil)
  let mounted = [ImageMounts.Mount(device: "/dev/disk42s2", path: "/fixture/Data")]
  try ImageMounts.verifyMounts(mounted, volume: volume, mountPoint: "/fixture/Data")
  #expect(throws: (any Error).self) {
    try ImageMounts.verifyMounts(mounted, volume: volume, mountPoint: nil)
  }
}

@Test func mountWaitAllowsOnlyPendingMounts() throws {
  let volume = volumeFixture()
  var queries = 0
  try ImageMounts.waitForMount(
    volume: volume, mountPoint: "/fixture/Data",
    refresh: {
      queries += 1
      return queries < 3 ? [] : [.init(device: "/dev/" + volume.device, path: "/fixture/Data")]
    }, pause: {})
  #expect(queries == 3)
}

@Test func mountWaitRejectsForeignAndDuplicateMountsImmediately() {
  let volume = volumeFixture()
  let foreign = ImageMounts.Mount(device: "/dev/" + volume.device, path: "/foreign/Data")
  let correct = ImageMounts.Mount(device: "/dev/" + volume.device, path: "/fixture/Data")
  for entries in [[foreign], [correct, correct]] {
    var queries = 0
    #expect(throws: (any Error).self) {
      try ImageMounts.waitForMount(
        volume: volume, mountPoint: "/fixture/Data",
        refresh: {
          queries += 1
          return entries
        }, pause: {})
    }
    #expect(queries == 1)
  }
}

@Test func mountWaitIsBoundedAndExplainsFailure() {
  var queries = 0
  do {
    try ImageMounts.waitForMount(
      volume: volumeFixture(), mountPoint: "/fixture/Data",
      refresh: {
        queries += 1
        return []
      }, pause: {})
    Issue.record("Missing mount was accepted")
  } catch {
    #expect(error.localizedDescription.contains("disk42s2"))
    #expect(error.localizedDescription.contains("/fixture/Data"))
    #expect(error.localizedDescription.contains("0 entries"))
  }
  #expect(queries == 10)
}

@Test func mountWaitPropagatesOwnershipFailure() {
  var queries = 0
  #expect(throws: (any Error).self) {
    try ImageMounts.waitForMount(
      volume: volumeFixture(), mountPoint: "/fixture/Data",
      refresh: {
        queries += 1
        throw MisoError.invalid("Changed attachment owner")
      }, pause: {})
  }
  #expect(queries == 1)
}

@Test func mountValidationIgnoresOtherDevicesButRequiresExactPaths() throws {
  let volume = volumeFixture()
  let other = ImageMounts.Mount(device: "/dev/disk142s2", path: "/fixture/Data")
  try ImageMounts.verifyMounts([other], volume: volume, mountPoint: nil)
  #expect(throws: (any Error).self) {
    try ImageMounts.verifyMounts([other], volume: volume, mountPoint: "/fixture/Data")
  }
  for path in ["/foreign/Data", "/fixture/Data/child"] {
    #expect(throws: (any Error).self) {
      try ImageMounts.verifyMounts(
        [.init(device: "/dev/" + volume.device, path: path)], volume: volume,
        mountPoint: "/fixture/Data")
    }
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MISO_MOUNT_SOURCE"] != nil))
func nativeImageMountLifecycle() throws {
  let environment = ProcessInfo.processInfo.environment
  let source = URL(fileURLWithPath: try #require(environment["MISO_MOUNT_SOURCE"]))
  let output = URL(fileURLWithPath: try #require(environment["MISO_MOUNT_OUTPUT"]))
  try #require(geteuid() == 0)
  let original = try FileMetadata.inspect(source)
  let journal = try ExecutionJournal(output: output, operation: "native-mount-lifecycle")
  try journal.perform {
    let image = output.appendingPathComponent("disk.img")
    try Artifacts.clone(source, to: image)
    for cycle in 0..<3 {
      let session = try DiskImageSession(image: image, readOnly: false, journal: journal)
      try session.withAttachment {
        let container = try BaseImageStage.mainContainer($0)
        let group = ImageMountGroup(session: $0, journal: journal)
        let data = try container.volume(role: "Data")
        let preboot = try container.volume(role: "Preboot")
        let root = output.appendingPathComponent("cycle-\(cycle)")
        try SafeFile.makeDirectory(root)
        let dataRoot = root.appendingPathComponent("Data")
        let prebootRoot = root.appendingPathComponent("Preboot")
        try SafeFile.makeDirectory(dataRoot)
        try SafeFile.makeDirectory(prebootRoot)
        do {
          try group.withCleanup {
            let mounted = try group.mount(data, name: "data", readOnly: false, at: dataRoot)
            let boot = try group.mount(preboot, name: "preboot", readOnly: true, at: prebootRoot)
            let account = try BaseImageStage.Account("admin", data: mounted)
            let probe = "private/tmp/miso-detach-probe"
            try mounted.makeDirectories(probe, uid: account.uid, gid: account.gid)
            let bytes = Data(repeating: UInt8(cycle), count: 128 << 10)
            for index in 0..<64 {
              try mounted.write(
                probe + "/\(index)", data: bytes, uid: account.uid, gid: account.gid)
            }
            try FileManager.default.removeItem(at: mounted.path(probe))
            let cryptexes = try FileManager.default.contentsOfDirectory(atPath: boot.root.path)
              .filter { UUID(uuidString: $0) != nil }
              .map {
                boot.root.appendingPathComponent($0 + "/cryptex1/current/os.dmg")
                  .resolvingSymlinksInPath()
              }.filter { FileManager.default.fileExists(atPath: $0.path) }
            let cryptexImage = try #require(cryptexes.count == 1 ? cryptexes.first : nil)
            try #require(cryptexImage.path.hasPrefix(boot.root.path + "/"))
            let cryptex = try DiskImageSession(
              image: cryptexImage, readOnly: true, journal: journal, forceReadOnlyDetach: true)
            var descriptor: Int32 = -1
            defer { if descriptor >= 0 { close(descriptor) } }
            let cryptexRoot = root.appendingPathComponent("Cryptex")
            try cryptex.withAttachment(requireGPT: false, mountPoint: cryptexRoot) { _ in
              descriptor = try SafeFile.openDirectory(cryptexRoot)
            }
            try session.verifyOwnership()
            if cycle == 1 { throw MisoError.invalid("Expected lifecycle body failure") }
          }
          #expect(cycle != 1)
        } catch {
          #expect(cycle == 1 && error.localizedDescription == "Expected lifecycle body failure")
        }
        try ImageMounts.verifyMounts(ImageMounts.mounts(), volume: data, mountPoint: nil)
        try ImageMounts.verifyMounts(ImageMounts.mounts(), volume: preboot, mountPoint: nil)
      }
    }
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment {
      let data = try BaseImageStage.mainContainer($0).volume(role: "Data")
      let mounted = try ImageMounts.mount(
        data, session: $0, journal: journal, name: "audit", readOnly: true)
      _ = try BaseImageStage.Account("admin", data: mounted)
    }
    try BaseStageWorkspace.requireUnmounted(output)
    let after = try FileMetadata.inspect(source)
    #expect(original.st_ino == after.st_ino && original.st_size == after.st_size)
    #expect(original.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
    #expect(original.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
    #expect(original.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec)
    #expect(original.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec)
    try FileManager.default.removeItem(at: image)
    return true
  }
}

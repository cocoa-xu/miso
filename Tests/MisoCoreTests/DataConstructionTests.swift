import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func guestWritesAreAtomicAndBoundToDirectoryIdentity() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  let expected = Data([1, 2, 3])
  try volume.write("nested/value", data: expected, uid: geteuid(), gid: getegid(), mode: 0o640)
  let directory = try volume.directory("nested")
  try directory.replace("value", data: Data([4]), uid: geteuid(), gid: getegid(), mode: 0o600)
  #expect(try SafeFile.read(volume.path("nested/value"), limit: 10) == Data([4]))
  #expect(try FileMetadata.inspect(volume.path("nested/value")).st_mode & 0o777 == 0o600)
  try FileManager.default.createSymbolicLink(
    at: directory.url.appendingPathComponent("link"),
    withDestinationURL: directory.url.appendingPathComponent("value"))
  for name in ["link", "../escape", "nested/escape"] {
    #expect(throws: (any Error).self) {
      try directory.replace(name, data: expected, uid: geteuid(), gid: getegid(), mode: 0o600)
    }
  }
  #expect(try SafeFile.read(volume.path("nested/value"), limit: 10) == Data([4]))
  try FileManager.default.moveItem(
    at: directory.url, to: temporary.url.appendingPathComponent("old"))
  try SafeFile.makeDirectory(directory.url)
  #expect(throws: (any Error).self) {
    try directory.replace("value", data: expected, uid: geteuid(), gid: getegid(), mode: 0o600)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
}

@Test func guestDirectoryChecksRejectSymlinksWithinTheirVolume() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let target = directory.url.appendingPathComponent("physical")
  try SafeFile.makeDirectory(target)
  let link = directory.url.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  let volume = try GuestVolume(directory.url)
  _ = try volume.directory("physical")
  #expect(throws: (any Error).self) { try volume.directory("alias") }
  #expect(throws: (any Error).self) {
    try volume.directory("alias/child")
  }
}

@Test func mountValidationUsesImageEntitiesWithoutAssumingAPFSMountPoints() throws {
  let volume = APFSTopology.Volume(
    device: "disk987s4", identifier: UUID(), roles: ["System"], name: nil, mountPoint: nil)
  let unmounted = DiskImageAttachment(entities: [
    .init(device: "/dev/disk987s4", contentHint: nil, mountPoint: nil)
  ])
  try ImageMounts.verifyAttachment(unmounted, volume: volume, mountPoint: nil)
  let mounted = DiskImageAttachment(entities: [
    .init(device: "/dev/disk987s4", contentHint: nil, mountPoint: "/fixture/system")
  ])
  try ImageMounts.verifyAttachment(mounted, volume: volume, mountPoint: "/fixture/system")
  for expected in [nil, "/fixture/other"] {
    #expect(throws: (any Error).self) {
      try ImageMounts.verifyAttachment(mounted, volume: volume, mountPoint: expected)
    }
  }
  #expect(throws: (any Error).self) {
    try ImageMounts.verifyAttachment(nil, volume: volume, mountPoint: nil)
  }
}

@Test func systemOverlaysRequireExactOwnedReadOnlyRestrictedMounts() throws {
  let root = URL(fileURLWithPath: "/fixture/system")
  let overlay = ImageMounts.SystemOverlay(
    volume: .init(
      device: "disk987s1", identifier: UUID(), roles: ["System"], name: nil, mountPoint: root.path),
    root: root)
  func validate(
    role: [String] = ["Data"], path: String = "System/Volumes/Data",
    device: String = "/dev/disk987s1", mountedAt: String = "/fixture/system",
    flags: UInt32 = UInt32(MNT_RDONLY | MNT_NOSUID), restricted: Bool = true
  ) throws {
    try overlay.validate(
      mount: root.appendingPathComponent(path), role: role, mountedFrom: device,
      mountedAt: mountedAt, flags: flags, restricted: restricted)
  }
  try validate()
  try validate(role: ["Preboot"], path: "System/Volumes/Preboot")
  for role in [[], ["System"], ["Data", "Preboot"]] {
    #expect(throws: (any Error).self) { try validate(role: role) }
  }
  for flags in [UInt32(0), UInt32(MNT_RDONLY), UInt32(MNT_NOSUID)] {
    #expect(throws: (any Error).self) { try validate(flags: flags) }
  }
  #expect(throws: (any Error).self) { try validate(device: "/dev/disk987s2") }
  #expect(throws: (any Error).self) { try validate(mountedAt: "/") }
  #expect(throws: (any Error).self) { try validate(path: "Users/admin") }
  #expect(throws: (any Error).self) { try validate(restricted: false) }
}

@Test func nativeTemplateCopyPreservesContentsLinksAndMetadata() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("source")
  let destination = directory.url.appendingPathComponent("destination")
  try SafeFile.makeDirectory(source)
  try SafeFile.makeDirectory(destination)
  try SafeFile.makeDirectory(source.appendingPathComponent("nested"))
  let file = source.appendingPathComponent("nested/value")
  try SafeFile.writeNew(Data([1, 2, 3, 4]), to: file)
  #expect(chmod(file.path, 0o754) == 0)
  let attribute = Data("metadata".utf8)
  #expect(
    attribute.withUnsafeBytes {
      setxattr(file.path, "user.miso-test", $0.baseAddress, $0.count, 0, 0)
    } == 0)
  try FileManager.default.createSymbolicLink(
    atPath: source.appendingPathComponent("relative").path, withDestinationPath: "nested/value")
  try FileManager.default.createSymbolicLink(
    atPath: source.appendingPathComponent("absolute").path,
    withDestinationPath: "/nonexistent/miso-test")
  let cancellation = try CancellationToken()
  try FileMetadata.copyTree(
    GuestVolume(source).directory(), to: GuestVolume(destination).directory(),
    cancellation: cancellation)
  #expect(
    !FileManager.default.fileExists(atPath: destination.appendingPathComponent("source").path))
  let result = try DataTemplate.audit(
    source: source, destination: GuestVolume(destination), cancellation: cancellation)
  #expect(result.entries == 4)
  #expect(result.regularFiles == 1 && result.logicalBytes == 4)
  #expect(
    try FileMetadata.attributes(
      destination.appendingPathComponent("nested/value"), ignoringCompression: false)[
        "user.miso-test"] == attribute)
  try SafeFile.replace(Data([4, 3, 2, 1]), at: destination.appendingPathComponent("nested/value"))
  #expect(throws: (any Error).self) {
    try DataTemplate.audit(
      source: source, destination: GuestVolume(destination), cancellation: cancellation)
  }
}

@Test func guestPathsRejectLinkParentsAndUnsafeLeaves() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let guest = try GuestVolume(directory.url)
  try FileManager.default.createSymbolicLink(
    atPath: directory.url.appendingPathComponent("outside").path, withDestinationPath: "/tmp")
  for relative in ["../escape", "outside/escape", "outside", "/absolute"] {
    #expect(throws: (any Error).self) { try guest.path(relative, createParents: true) }
  }
  #expect(try guest.path("outside", allowLeafLink: true).lastPathComponent == "outside")
  try guest.write("new/inside", data: Data([9]), uid: geteuid(), gid: getegid())
  #expect(try SafeFile.read(guest.path("new/inside"), limit: 10) == Data([9]))
  let cancelled = try CancellationToken()
  cancelled.cancel()
  let target = directory.url.appendingPathComponent("target")
  try SafeFile.makeDirectory(target)
  #expect(throws: (any Error).self) {
    try FileMetadata.copyTree(
      guest.directory(), to: guest.directory("target"), cancellation: cancelled)
  }
}

@Test func offlineAccountUsesValidatedPasswordAndVersionedSetupKeys() throws {
  var configuration = ImageConfiguration()
  configuration.password = "test-密碼"
  let identifier = UUID()
  let record = try OfflineAccount.record(configuration: configuration, identifier: identifier)
  #expect(record["uid"] as? [String] == ["501"])
  #expect(record["generateduid"] as? [String] == [identifier.uuidString])
  let hash = try #require((record["ShadowHashData"] as? [Data])?.first)
  #expect(try OfflineAccount.verifyPassword(hash, password: configuration.password))
  #expect(try !OfflineAccount.verifyPassword(hash, password: configuration.password + "wrong"))
  #expect(
    OfflineAccount.loginPassword("admin").map { String(format: "%02x", $0) }.joined()
      == "1ced3f4abcbca1b9a3b91f7d")
  #expect(OfflineAccount.vncPassword("admin") == Data("76503C07E5A8C5E2FF1C39567390ADCA".utf8))
  for profile in RestoreProfile.supported {
    let preferences = OfflineAccount.setupPreferences(profile)
    #expect(preferences["LastSeenBuddyBuildVersion"] as? String == profile.release.build)
    for key in profile.setupVersionKeys {
      #expect(preferences[key] as? String == profile.release.version)
    }
    for key in profile.setupCompletedKeys { #expect(preferences[key] as? Bool == true) }
  }
}

@Test func guestPlistMergePreservesUnrelatedNestedValues() throws {
  let merged = GuestVolume.merge(
    ["nested": ["keep": 1, "change": 2], "original": true], ["nested": ["change": 3]])
  #expect(merged["original"] as? Bool == true)
  #expect(merged["nested"] as? [String: Int] == ["keep": 1, "change": 3])
}

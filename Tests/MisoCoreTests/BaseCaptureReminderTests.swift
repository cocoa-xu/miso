import Darwin
import Foundation
import Testing

@testable import MisoCore

private let captureExpiry = Date(timeIntervalSince1970: 4_102_444_800)
private let captureTarget = MacOSRelease(version: "26.6.2", build: "25G83")

private func capturePolicy(hash: String = String(repeating: "a", count: 64))
  -> BaseCaptureReminder.Policy
{
  .init(schemaVersion: 1, replaydSHA256: hash, expiresAt: captureExpiry)
}

private func captureVolume(_ temporary: TemporaryDirectory) throws -> GuestVolume {
  try GuestVolume(temporary.url)
}

@Test func capturePolicyBindsVersionExpiryAndImplementation() throws {
  let policy = capturePolicy()
  try policy.validate(target: captureTarget, now: captureExpiry.addingTimeInterval(-1))
  for version in ["15.6.1", "27.0"] {
    #expect(throws: (any Error).self) {
      try policy.validate(target: .init(version: version, build: "unknown"))
    }
  }
  #expect(throws: (any Error).self) {
    try policy.validate(target: captureTarget, now: captureExpiry)
  }
  #expect(throws: (any Error).self) {
    try capturePolicy(hash: "invalid").validate(target: captureTarget)
  }
  for invalid in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
    #expect(throws: (any Error).self) {
      try BaseCaptureReminder.Policy(
        schemaVersion: 1, replaydSHA256: policy.replaydSHA256,
        expiresAt: invalid
      ).validate(target: captureTarget)
    }
  }
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let binary = temporary.url.appendingPathComponent("replayd")
  let bytes = Data("target implementation".utf8)
  try SafeFile.writeNew(bytes, to: binary)
  try capturePolicy(hash: SafeFile.sha256(bytes)).verifyImplementation(binary)
  #expect(throws: (any Error).self) { try policy.verifyImplementation(binary) }
}

@Test func captureReminderRequiresGrantAndPreservesExistingState() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try captureVolume(temporary)
  let policy = capturePolicy()
  let grants = try BaseTCC.grants(
    agent: "opt/homebrew/Cellar/tart-guest-agent/1.0/bin/tart-guest-agent")
  #expect(throws: (any Error).self) {
    try BaseCaptureReminder.seed(
      policy, data: volume, home: "Users/test", uid: getuid(), gid: getgid(), grants: [])
  }
  #expect(!(try volume.contains("Users")))
  let path = try BaseCaptureReminder.seed(
    policy, data: volume, home: "Users/test", uid: getuid(), gid: getgid(), grants: grants)
  let url = try volume.path(path)
  try BaseCaptureReminder.verify(url, uid: getuid(), gid: getgid())
  #expect(NSDictionary(dictionary: try volume.plist(path)).isEqual(to: policy.preferences))
  let digest = try SafeFile.sha256(url)
  #expect(throws: (any Error).self) {
    try BaseCaptureReminder.seed(
      policy, data: volume, home: "Users/test", uid: getuid(), gid: getgid(), grants: grants)
  }
  #expect(try SafeFile.sha256(url) == digest)
  #expect(throws: (any Error).self) {
    try BaseCaptureReminder.verify(url, uid: getuid() + 1, gid: getgid())
  }
  #expect(chmod(url.path, 0o644) == 0)
  #expect(throws: (any Error).self) {
    try BaseCaptureReminder.verify(url, uid: getuid(), gid: getgid())
  }
}

@Test func captureReminderRejectsUnsafeDirectoriesAndLinks() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try captureVolume(temporary)
  let grants = try BaseTCC.grants(
    agent: "opt/homebrew/Cellar/tart-guest-agent/1.0/bin/tart-guest-agent")
  let directory = "Users/test/Library/Group Containers"
  try volume.makeDirectories(directory, uid: getuid(), gid: getgid())
  #expect(throws: (any Error).self) {
    try BaseCaptureReminder.seed(
      capturePolicy(), data: volume, home: "Users/test", uid: getuid(), gid: getgid(),
      grants: grants)
  }
  #expect(chmod(try volume.path(directory).path, 0o700) == 0)
  let link = try volume.path(directory + "/group.com.apple.replayd")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: volume.root)
  #expect(throws: (any Error).self) {
    try BaseCaptureReminder.seed(
      capturePolicy(), data: volume, home: "Users/test", uid: getuid(), gid: getgid(),
      grants: grants)
  }
}

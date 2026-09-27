import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func guestCleanupRemovesOwnedCacheWithoutFollowingLinks() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  try volume.makeDirectories("cache/nested/child", uid: getuid(), gid: getgid())
  try volume.write(
    "cache/nested/child/file", data: Data("cache".utf8), uid: getuid(), gid: getgid())
  try volume.write("preserved", data: Data("keep".utf8), uid: getuid(), gid: getgid())
  #expect(symlink("../../preserved", try volume.path("cache/nested/link").path) == 0)
  #expect(
    try GuestCleanup.removeDirectory("cache/nested", volume: volume, uid: getuid(), gid: getgid())
      == 4)
  #expect(try !volume.contains("cache/nested"))
  #expect(try SafeFile.read(volume.path("preserved"), limit: 8) == Data("keep".utf8))
  #expect(
    try GuestCleanup.removeDirectory("cache/absent", volume: volume, uid: getuid(), gid: getgid())
      == 0)
}

@Test func guestCleanupRejectsUnsafeScopeOwnershipAndFileTypesBeforeRemoval() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  try volume.makeDirectories("cache/nested", uid: getuid(), gid: getgid())
  try volume.write("cache/nested/file", data: Data("keep".utf8), uid: getuid(), gid: getgid())
  for path in ["cache", "../cache/nested", "/cache/nested"] {
    #expect(throws: (any Error).self) {
      try GuestCleanup.removeDirectory(path, volume: volume, uid: getuid(), gid: getgid())
    }
  }
  #expect(throws: (any Error).self) {
    try GuestCleanup.removeDirectory(
      "cache/nested", volume: volume, uid: getuid() + 1, gid: getgid())
  }
  #expect(throws: (any Error).self) {
    try GuestCleanup.removeDirectory(
      "cache/nested", volume: volume, uid: getuid() + 1, gid: getgid(),
      rootOwner: (getuid(), getgid()))
  }
  #expect(mkfifo(try volume.path("cache/nested/fifo").path, 0o600) == 0)
  #expect(throws: (any Error).self) {
    try GuestCleanup.removeDirectory("cache/nested", volume: volume, uid: getuid(), gid: getgid())
  }
  #expect(try volume.contains("cache/nested/file"))
  #expect(symlink("cache", temporary.url.appendingPathComponent("alias").path) == 0)
  #expect(throws: (any Error).self) {
    try GuestCleanup.removeDirectory("alias/nested", volume: volume, uid: getuid(), gid: getgid())
  }
}

@Test func baseCleanupPlansBindTargetTrustAndExecutablePaths() throws {
  let plan = BaseCleanup.Plan(
    schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"),
    nodeFormula: "node@24", pythonFormula: "python@3.14", pythonExecutable: "python3.14",
    rubyVersions: ["4.0.7", "2.7.8"],
    certificateBundle: .init(
      path: BaseCertificates.destination, bytes: 100, sha256: String(repeating: "a", count: 64)),
    certificateCount: 200)
  try plan.validate()
  let json = String(decoding: try JSON.encode(plan), as: UTF8.self)
  for (original, replacement) in [
    ("python3.14", "python3.13"), ("node@24", "../../outside"),
    ("4.0.7", "../4.0.7"), (BaseCertificates.destination, "private/etc/ssl/cert.pem"),
  ] {
    let altered = try JSONDecoder().decode(
      BaseCleanup.Plan.self,
      from: Data(json.replacingOccurrences(of: original, with: replacement).utf8))
    #expect(throws: (any Error).self) { try altered.validate() }
  }
  #expect(!BaseCleanup.cachePaths(username: "admin").contains("Users/admin"))
  #expect(!BaseCleanup.cachePaths(username: "admin").contains("opt/homebrew"))
}

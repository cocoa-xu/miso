import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func explicitDirectoryPermissionsDoNotInheritTheProcessUmask() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  for mode: mode_t in [0o700, 0o711, 0o755] {
    let directory = temporary.url.appendingPathComponent(String(mode))
    try SafeFile.makeDirectory(directory, mode: mode)
    #expect(try FileMetadata.inspect(directory).st_mode & 0o7777 == mode)
  }
  #expect(throws: (any Error).self) {
    try SafeFile.makeDirectory(temporary.url.appendingPathComponent("set-id"), mode: 0o4755)
  }
}

@Test func descriptorTraversalRejectsSymlinkParentsAndLeaves() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let root = temporary.url
  let physical = root.appendingPathComponent("physical")
  try SafeFile.makeDirectory(physical)
  let alias = root.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
  try SafeFile.writeNew(Data([1]), to: physical.appendingPathComponent("file"))
  try SafeFile.requireNoSymlinks(physical)
  try SafeFile.requireNoSymlinks(physical.appendingPathComponent("file"))
  for path in [alias, alias.appendingPathComponent("file")] {
    #expect(throws: (any Error).self) { try SafeFile.requireNoSymlinks(path) }
  }
  #expect(throws: (any Error).self) { try GuestVolume(alias) }
  #expect(throws: (any Error).self) {
    try SafeFile.makeDirectory(alias.appendingPathComponent("escaped-directory"))
  }
  #expect(throws: (any Error).self) {
    try SafeFile.writeNew(Data([2]), to: alias.appendingPathComponent("escaped-file"))
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: physical.path) == ["file"])
  let leaf = physical.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(
    at: leaf, withDestinationURL: physical.appendingPathComponent("file"))
  #expect(throws: (any Error).self) { try SafeFile.requireNoSymlinks(leaf) }
  #expect(throws: (any Error).self) { try SafeFile.writeNew(Data([3]), to: leaf) }
  #expect(try SafeFile.read(physical.appendingPathComponent("file"), limit: 8) == Data([1]))
}

@Test func guestParentsHaveExplicitModesAndUserCachesKeepTheirOwner() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  _ = try volume.path("Library/Application Support/miso/receipt", createParents: true)
  for relative in ["Library", "Library/Application Support", "Library/Application Support/miso"] {
    #expect(try FileMetadata.inspect(volume.path(relative)).st_mode & 0o7777 == 0o755)
  }
  try SafeFile.makeDirectory(temporary.url.appendingPathComponent("user"), mode: 0o700)
  try volume.makeDirectories("user/Library/Caches/Homebrew", uid: getuid(), gid: getgid())
  #expect(try FileMetadata.inspect(volume.path("user")).st_mode & 0o7777 == 0o700)
  for relative in ["user/Library", "user/Library/Caches", "user/Library/Caches/Homebrew"] {
    let info = try FileMetadata.inspect(volume.path(relative))
    #expect(info.st_uid == getuid() && info.st_gid == getgid())
    #expect(info.st_mode & 0o7777 == 0o755)
  }
}

@Test func descriptorTraversalAcceptsAPFSFirmlinkDirectoriesWithoutRewritingPaths() throws {
  let path = URL(fileURLWithPath: "/System/Volumes/Data/Users")
  guard FileManager.default.fileExists(atPath: path.path) else { return }
  let descriptor = try SafeFile.openDirectory(path)
  defer { close(descriptor) }
  var actual = stat()
  #expect(fstat(descriptor, &actual) == 0)
  let expected = try FileMetadata.inspect(URL(fileURLWithPath: "/Users"))
  #expect(actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino)
  #expect(try GuestVolume(path).root == path)
}

@Test func commandLineToolsRejectInaccessibleParentsBeforeGuestInstallation() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  for directory in [
    "Library/Developer/CommandLineTools/usr/bin", "Library/Apple/System/Library/Receipts",
  ] {
    try volume.makeDirectories(directory, uid: getuid(), gid: getgid())
  }
  try CommandLineTools.requireGuestAccess(volume)
  for directory in ["Library/Developer", "Library/Apple/System/Library"] {
    let path = try volume.path(directory)
    #expect(chmod(path.path, 0o700) == 0)
    #expect(throws: (any Error).self) { try CommandLineTools.requireGuestAccess(volume) }
    #expect(chmod(path.path, 0o755) == 0)
  }
  try CommandLineTools.requireGuestAccess(volume)
}

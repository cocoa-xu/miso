import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func bundleSnapshotDetectsSameSizeWritesAndReplacement() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  for name in ImageBundle.requiredFiles {
    try SafeFile.writeNew(Data("before".utf8), to: directory.url.appendingPathComponent(name))
  }
  let before = try ImageBundle.snapshot(directory.url)
  let file = try SafeFile.openRegular(
    directory.url.appendingPathComponent("disk.img"), writable: true)
  try file.write(contentsOf: Data("after!".utf8))
  try file.close()
  let changed = try ImageBundle.snapshot(directory.url)
  #expect(before != changed)
  try SafeFile.replace(Data("after!".utf8), at: directory.url.appendingPathComponent("disk.img"))
  #expect(try ImageBundle.snapshot(directory.url) != changed)
}

@Test func compressionPreservesContentsHardlinksAndMetadata() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let volume = try GuestVolume(directory.url)
  try volume.makeDirectories("payload/nested", uid: getuid(), gid: getgid())
  let content = Data(repeating: 0x41, count: 180_123)
  try volume.write("payload/file", data: content, uid: getuid(), gid: getgid(), mode: 0o750)
  let original = try volume.path("payload/file")
  let alias = try volume.path("payload/nested/link")
  #expect(link(original.path, alias.path) == 0)
  var access = acl_init(1)
  defer { if let access { acl_free(UnsafeMutableRawPointer(access)) } }
  var entry: acl_entry_t?
  var permissions: acl_permset_t?
  var principal = UUID().uuid
  try #require(acl_create_entry(&access, &entry) == 0)
  try #require(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0)
  try #require(acl_set_qualifier(entry, &principal) == 0)
  try #require(acl_get_permset(entry, &permissions) == 0)
  try #require(acl_add_perm(permissions, ACL_READ_DATA) == 0)
  try #require(acl_set_file(original.path, ACL_TYPE_EXTENDED, access) == 0)
  let originalACL = try #require(try FileMetadata.acl(original))
  let attribute = Data("preserved".utf8)
  #expect(
    attribute.withUnsafeBytes {
      setxattr(original.path, "miso.test", $0.baseAddress, $0.count, 0, 0)
    } == 0)
  let before = try FileMetadata.inspect(original)
  let result = try TransparentCompression.run(
    data: volume, roots: ["payload"], workspace: directory.url,
    cancellation: CancellationToken())
  let after = try FileMetadata.inspect(original)
  #expect(result.filesCompressed == 1 && result.pathsCompressed == 2 && result.bytesSaved > 0)
  #expect(try SafeFile.read(original, limit: 1 << 20) == content)
  #expect(try FileMetadata.inspect(alias).st_ino == after.st_ino && after.st_nlink == 2)
  #expect(after.st_flags & UInt32(UF_COMPRESSED) != 0)
  #expect(FileMetadata.equivalent(before, after))
  #expect(try FileMetadata.acl(original) == originalACL)
  #expect(
    after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
      && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
  #expect(
    try FileMetadata.attributes(original, ignoringCompression: true)["miso.test"] == attribute)
  let repeated = try TransparentCompression.run(
    data: volume, roots: ["payload"], workspace: directory.url,
    cancellation: CancellationToken())
  #expect(repeated.filesCompressed == 0)
}

@Test func compressionLeavesExcludedFilesAndExternalHardlinksUntouched() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let volume = try GuestVolume(directory.url)
  try volume.makeDirectories("payload", uid: getuid(), gid: getgid())
  let content = Data(repeating: 0x41, count: 80_000)
  for name in ["archive.dmg", "state.sqlite", "linked", "forked"] {
    try volume.write("payload/" + name, data: content, uid: getuid(), gid: getgid())
  }
  try volume.write("payload/small", data: Data([1, 2]), uid: getuid(), gid: getgid())
  #expect(link(try volume.path("payload/linked").path, try volume.path("external").path) == 0)
  #expect(symlink("../external", try volume.path("payload/symlink").path) == 0)
  let forked = try volume.path("payload/forked")
  #expect(
    content.prefix(10).withUnsafeBytes {
      setxattr(forked.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
    } == 0)
  let result = try TransparentCompression.run(
    data: volume, roots: ["payload"], workspace: directory.url,
    cancellation: CancellationToken())
  #expect(result.filesCompressed == 0)
  #expect(try SafeFile.read(volume.path("external"), limit: 1 << 20) == content)
  let token = try CancellationToken()
  token.cancel()
  #expect(throws: CancellationError.self) {
    try TransparentCompression.run(
      data: volume, roots: ["payload"], workspace: directory.url,
      cancellation: token)
  }
}

@Test func compactionPunchesOnlyBitmapFreeBlocks() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let fixture = APFSCompactionFixture()
  let url = directory.url.appendingPathComponent("disk.img")
  try SafeFile.writeNew(fixture.bytes, to: url)
  let file = try SafeFile.openRegular(url, writable: true)
  defer { try? file.close() }
  let receipt = try APFSCompaction.compact(file, cancellation: CancellationToken())
  #expect(
    receipt.freeBytes == 16 * 4096 && receipt.allocatedBytesAfter < receipt.allocatedBytesBefore)
  let output = try SafeFile.read(url, limit: 1 << 20)
  #expect(output.prefix(fixture.freeOffset) == fixture.bytes.prefix(fixture.freeOffset))
  #expect(output[fixture.freeOffset..<(fixture.freeOffset + 16 * 4096)].allSatisfy { $0 == 0 })
  #expect(
    output.suffix(from: fixture.freeOffset + 16 * 4096)
      == fixture.bytes.suffix(from: fixture.freeOffset + 16 * 4096))
}

@Test(arguments: [
  "free-count", "metadata-free", "address-overflow", "checkpoint", "backup-gpt", "indirection",
])
func compactionRejectsInvalidMetadataBeforeWriting(_ fault: String) throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  var fixture = APFSCompactionFixture()
  switch fault {
  case "free-count": fixture.changeBlock(8) { $0.put(UInt32(17), at: 60) }
  case "metadata-free":
    fixture.bytes[fixture.base + 9 * 4096] &= 0xfe
    fixture.bytes[fixture.base + 9 * 4096 + 2] |= 1
  case "address-overflow": fixture.changeBlock(5) { $0.put(UInt64.max, at: 512) }
  case "checkpoint": fixture.changeBlock(2) { $0.put(UInt32(1), at: 136) }
  case "indirection": fixture.changeBlock(5) { $0.put(UInt32(1), at: 68) }
  default: fixture.bytes[fixture.bytes.count - 512 + 16] ^= 1
  }
  let url = directory.url.appendingPathComponent("disk.img")
  try SafeFile.writeNew(fixture.bytes, to: url)
  let file = try SafeFile.openRegular(url, writable: true)
  defer { try? file.close() }
  #expect(throws: (any Error).self) {
    try APFSCompaction.compact(file, cancellation: CancellationToken())
  }
  #expect(try SafeFile.read(url, limit: 1 << 20) == fixture.bytes)
}

private struct APFSCompactionFixture {
  let base = 40 * 512
  var freeOffset: Int { base + 16 * 4096 }
  var bytes = Data(repeating: 0xa5, count: 400 * 512)

  init() {
    var entries = Data(count: 128 * 128)
    entries.replaceSubrange(0..<16, with: DiskLayout.apfsType.gptBytes)
    entries.put(UInt64(40), at: 32)
    entries.put(UInt64(295), at: 40)
    func header(_ current: UInt64, _ backup: UInt64, _ table: UInt64) -> Data {
      var data = Data(count: 512)
      data.replaceSubrange(0..<8, with: Data("EFI PART".utf8))
      data.put(UInt32(92), at: 12)
      data.put(current, at: 24)
      data.put(backup, at: 32)
      data.put(UInt64(34), at: 40)
      data.put(UInt64(366), at: 48)
      data.put(table, at: 72)
      data.put(UInt32(128), at: 80)
      data.put(UInt32(128), at: 84)
      data.put(entries.crc32, at: 88)
      data.put(data.prefix(92).crc32, at: 16)
      return data
    }
    bytes.replaceSubrange(512..<1024, with: header(1, 399, 2))
    bytes.replaceSubrange(1024..<(1024 + entries.count), with: entries)
    bytes.replaceSubrange((367 * 512)..<(399 * 512), with: entries)
    bytes.replaceSubrange((399 * 512)..<(400 * 512), with: header(399, 1, 367))
    for block in [0, 2] {
      changeBlock(block, clear: true) {
        $0.put(UInt64(7), at: 16)
        $0.put(UInt32(1), at: 24)
        $0.put(UInt32(0x4253_584e), at: 32)
        $0.put(UInt32(4096), at: 36)
        $0.put(UInt64(32), at: 40)
        $0.put(UInt32(4), at: 104)
        $0.put(UInt32(2), at: 108)
        $0.put(UInt64(1), at: 112)
        $0.put(UInt64(5), at: 120)
        $0.put(UInt32(2), at: 140)
        $0.put(UInt64(100), at: 152)
      }
    }
    changeBlock(1, clear: true) {
      $0.put(UInt64(7), at: 16)
      $0.put(UInt32(12), at: 24)
      $0.put(UInt32(1), at: 32)
      $0.put(UInt32(1), at: 36)
      $0.put(UInt32(5), at: 40)
      $0.put(UInt32(4096), at: 48)
      $0.put(UInt64(100), at: 64)
      $0.put(UInt64(5), at: 72)
    }
    changeBlock(5, clear: true) {
      $0.put(UInt64(100), at: 8)
      $0.put(UInt64(7), at: 16)
      $0.put(UInt32(5), at: 24)
      $0.put(UInt32(4096), at: 32)
      $0.put(UInt32(32768), at: 36)
      $0.put(UInt64(32), at: 48)
      $0.put(UInt64(1), at: 56)
      $0.put(UInt32(1), at: 64)
      $0.put(UInt64(16), at: 72)
      $0.put(UInt32(512), at: 80)
      $0.put(UInt64(4), at: 152)
      $0.put(UInt32(1), at: 164)
      $0.put(UInt64(14), at: 168)
      $0.put(UInt64(10), at: 176)
      $0.put(UInt64(8), at: 512)
    }
    changeBlock(8, clear: true) {
      $0.put(UInt64(7), at: 16)
      $0.put(UInt32(7), at: 24)
      $0.put(UInt32(1), at: 36)
      $0.put(UInt64(7), at: 40)
      $0.put(UInt32(32), at: 56)
      $0.put(UInt32(16), at: 60)
      $0.put(UInt64(9), at: 64)
    }
    bytes.replaceSubrange((base + 9 * 4096)..<(base + 10 * 4096), with: Data(count: 4096))
    bytes[base + 9 * 4096] = 0xff
    bytes[base + 9 * 4096 + 1] = 0xff
  }

  mutating func changeBlock(_ block: Int, clear: Bool = false, _ body: (inout Data) -> Void) {
    let offset = base + block * 4096
    var data = clear ? Data(count: 4096) : Data(bytes[offset..<(offset + 4096)])
    body(&data)
    var sum: UInt64 = 0
    var weighted: UInt64 = 0
    let modulus: UInt64 = 0xffff_ffff
    for offset in stride(from: 8, to: 4096, by: 4) {
      sum = (sum + UInt64(try! data.integer(at: offset, as: UInt32.self))) % modulus
      weighted = (weighted + sum) % modulus
    }
    let lower = modulus - (sum + weighted) % modulus
    data.put(lower | ((modulus - (sum + lower) % modulus) << 32), at: 0)
    bytes.replaceSubrange(offset..<(offset + 4096), with: data)
  }
}

import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func intelTrimmingPreservesAppleSignaturesARMSubtypesAndHardlinks() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  try volume.makeDirectories("tools/bin", uid: getuid(), gid: getgid())
  let tool = try volume.path("tools/bin/true")
  try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)
  let bytes = try SafeFile.read(tool, limit: 4 << 20)
  let original = try IntelTrimming.slices(bytes, size: UInt64(bytes.count))
  #expect(original.contains { $0.intel })
  let linkPath = try volume.path("tools/bin/alias")
  #expect(link(tool.path, linkPath.path) == 0)
  #expect(throws: Never.self) { try AppleCode.validate(tool, scope: .executable) }
  let result = try IntelTrimming.run(
    data: volume, roots: ["tools"], cancellation: CancellationToken())
  #expect(result.filesTrimmed == 1)
  let trimmed = try SafeFile.read(tool, limit: 4 << 20)
  let slices = try IntelTrimming.slices(trimmed, size: UInt64(trimmed.count))
  #expect(slices.map(\.subtype) == original.filter(\.arm64).map(\.subtype))
  for (before, after) in zip(original.filter(\.arm64), slices) {
    #expect(
      bytes[Int(before.offset)..<Int(before.offset + before.size)]
        == trimmed[Int(after.offset)..<Int(after.offset + after.size)])
  }
  #expect(try FileMetadata.inspect(tool).st_ino == FileMetadata.inspect(linkPath).st_ino)
  #expect(throws: Never.self) { try AppleCode.validate(tool, scope: .executable) }
  #expect(
    try IntelTrimming.run(data: volume, roots: ["tools"], cancellation: CancellationToken())
      .filesTrimmed == 0)
}

@Test func intelTrimmingLeavesExternalHardlinksAndSymlinksUntouched() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  try volume.makeDirectories("tools/bin", uid: getuid(), gid: getgid())
  let tool = try volume.path("tools/bin/true")
  try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)
  #expect(link(tool.path, try volume.path("outside").path) == 0)
  #expect(symlink("/usr/bin/true", try volume.path("tools/bin/system").path) == 0)
  let info = try FileMetadata.inspect(tool)
  let result = try IntelTrimming.run(
    data: volume, roots: ["tools"], cancellation: CancellationToken())
  #expect(result.incompleteHardlinks == 1)
  #expect(result.filesTrimmed == 0 && result.filesRemoved == 0)
  #expect(try FileMetadata.inspect(tool).st_size == info.st_size)
}

@Test func universalSliceBoundsRejectOverlapsAndOverflow() throws {
  var bytes = try SafeFile.read(URL(fileURLWithPath: "/usr/bin/true"), limit: 4 << 20)
  let magic = try bytes.integer(at: 0, as: UInt32.self)
  #expect(magic == 0xBEBA_FECA)
  bytes.put(UInt32(0xFFFF_FFFF).bigEndian, at: 4)
  #expect(throws: MisoError.self) { try IntelTrimming.slices(bytes, size: UInt64(bytes.count)) }
  bytes.put(UInt32(2).bigEndian, at: 4)
  bytes.put(UInt32(1).bigEndian, at: 16)
  #expect(throws: MisoError.self) { try IntelTrimming.slices(bytes, size: UInt64(bytes.count)) }
}

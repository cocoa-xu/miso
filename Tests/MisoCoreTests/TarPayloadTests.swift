import Darwin
import Foundation
import Testing

@testable import MisoCore

private func tarEntry(
  path: String, type: UInt8 = 48, content: Data = Data(), link: String = "", mode: UInt16 = 0o755
) -> Data {
  var header = Data(repeating: 0, count: 512)
  func field(_ text: String, at offset: Int, width: Int) {
    let value = Array(text.utf8.prefix(width))
    header.replaceSubrange(offset..<(offset + value.count), with: value)
  }
  field(path, at: 0, width: 100)
  field(String(format: "%07o", mode), at: 100, width: 8)
  field("0000000", at: 108, width: 8)
  field("0000000", at: 116, width: 8)
  field(String(format: "%011o", content.count), at: 124, width: 12)
  field("00000000000", at: 136, width: 12)
  field("        ", at: 148, width: 8)
  header[156] = type
  field(link, at: 157, width: 100)
  field("ustar", at: 257, width: 6)
  field("00", at: 263, width: 2)
  let checksum = header.reduce(0) { $0 + Int($1) }
  field(String(format: "%06o", checksum) + "\0 ", at: 148, width: 8)
  return header + content + Data(repeating: 0, count: (512 - content.count % 512) % 512)
}

@Test func nativeTarExtractsBytesModesAndLinksWithoutSubprocesses() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("payload.tar")
  let content = Data(repeating: 42, count: (1 << 20) + 101)
  let bytes =
    tarEntry(path: "bin/tool", content: content)
    + tarEntry(path: "tool", type: 50, link: "bin/tool")
    + tarEntry(path: "bin/alias", type: 49, link: "bin/tool") + Data(repeating: 0, count: 1024)
  try SafeFile.writeNew(bytes, to: source)
  let entries = try TarPayload.inspect(source)
  #expect(entries.count == 3)
  let output = directory.url.appendingPathComponent("out")
  try SafeFile.makeDirectory(output)
  try TarPayload.extract(source, into: output, entries: entries, uid: getuid(), gid: getgid())
  #expect(try SafeFile.read(output.appendingPathComponent("bin/tool"), limit: 2 << 20) == content)
  #expect(
    try FileMetadata.inspect(output.appendingPathComponent("bin/tool")).st_mode & 0o777 == 0o755)
  #expect(
    try FileMetadata.inspect(output.appendingPathComponent("bin/tool")).st_ino
      == FileMetadata.inspect(output.appendingPathComponent("bin/alias")).st_ino)
  #expect(try SafeFile.read(output.appendingPathComponent("bin/alias"), limit: 2 << 20) == content)
  #expect(
    try FileManager.default.destinationOfSymbolicLink(
      atPath: output.appendingPathComponent("tool").path) == "bin/tool")
  #expect(throws: (any Error).self) {
    try TarPayload.extract(source, into: output, entries: entries, uid: getuid(), gid: getgid())
  }
}

@Test func nativeTarRejectsTraversalSpecialEntriesAndLinkParents() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let cases = [
    tarEntry(path: "../escape"), tarEntry(path: "/absolute"),
    tarEntry(path: "special", type: 54), tarEntry(path: "setid", mode: 0o4755),
    tarEntry(path: "link", type: 49, link: "target"),
    tarEntry(path: "link", type: 50, link: "../outside"),
    tarEntry(path: "link", type: 50, link: "/outside"),
    tarEntry(path: "link", type: 50, link: "link"),
    tarEntry(path: "d/a", type: 50, link: "../target")
      + tarEntry(path: "escape", type: 50, link: "d/a/../../outside"),
    tarEntry(path: "duplicate") + tarEntry(path: "duplicate"),
    tarEntry(path: "link", type: 50, link: "target") + tarEntry(path: "link/child"),
  ]
  for (index, bytes) in cases.enumerated() {
    let path = directory.url.appendingPathComponent("bad-\(index).tar")
    try SafeFile.writeNew(bytes + Data(repeating: 0, count: 1024), to: path)
    #expect(throws: (any Error).self) { try TarPayload.inspect(path) }
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MISO_RUNNER_ARCHIVE"] != nil))
func nativeTarReadsRetainedRunnerRelease() throws {
  let source = URL(
    fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MISO_RUNNER_ARCHIVE"]))
  let entries = try TarPayload.inspect(source)
  #expect(entries.contains { $0.path == "bin/Runner.Listener" && $0.kind == S_IFREG })
  #expect(entries.contains { $0.path == "run.sh" && $0.kind == S_IFREG })
}

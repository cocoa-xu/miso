import Darwin
import Foundation
import Testing
import ZIPFoundation

@testable import MisoCore

@Test func nativeZIPPreservesExecutableAndFrameworkLinks() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let tree = temporary.url.appendingPathComponent("tree")
  try SafeFile.makeDirectory(tree)
  let binary = tree.appendingPathComponent("tool")
  try SafeFile.writeNew(Data("executable".utf8), to: binary)
  #expect(chmod(binary.path, 0o755) == 0)
  #expect(symlink("tool", tree.appendingPathComponent("link").path) == 0)
  let input = temporary.url.appendingPathComponent("payload.zip")
  let archive = try Archive(url: input, accessMode: .create)
  try archive.addEntry(with: "tool", relativeTo: tree)
  try archive.addEntry(with: "link", relativeTo: tree)
  let output = temporary.url.appendingPathComponent("out")
  try ZIPPayload.extract(input, to: output)
  #expect(
    try SafeFile.read(output.appendingPathComponent("tool"), limit: 16) == Data("executable".utf8))
  #expect(try FileMetadata.inspect(output.appendingPathComponent("tool")).st_mode & 0o777 == 0o755)
  #expect(
    try FileManager.default.destinationOfSymbolicLink(
      atPath: output.appendingPathComponent("link").path) == "tool")
  #expect(throws: (any Error).self) { try ZIPPayload.extract(input, to: output) }
  #expect(throws: (any Error).self) {
    try ZIPPayload.extract(
      input, to: temporary.url.appendingPathComponent("small"), maximumBytes: 5)
  }
}

@Test func nativeZIPRejectsEscapingLinksAndTraversalBeforeExtraction() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let tree = temporary.url.appendingPathComponent("tree")
  try SafeFile.makeDirectory(tree)
  #expect(symlink("../outside", tree.appendingPathComponent("link").path) == 0)
  let link = temporary.url.appendingPathComponent("link.zip")
  let archive = try Archive(url: link, accessMode: .create)
  try archive.addEntry(with: "link", relativeTo: tree)
  let traversal = temporary.url.appendingPathComponent("traversal.zip")
  try zipFixture(at: traversal, members: [("../outside", Data("bad".utf8))])
  for input in [link, traversal] {
    let output = temporary.url.appendingPathComponent(UUID().uuidString)
    #expect(throws: (any Error).self) { try ZIPPayload.extract(input, to: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }
}

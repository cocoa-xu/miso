import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func executionFirmlinksAreExplicitAndBounded() throws {
  #expect(
    try BaseExecutionView.firmlinks("# mappings\n/Library\tLibrary\n/usr/local usr/local\n") == [
      "Library": "Library", "usr/local": "usr/local",
    ])
  for text in [
    "", "/Library Library\n/Library Library", "/dev dev", "/System/Volumes/Data Data",
    "/../outside outside", "/Library ../Library", "Library Library", "/Library Library extra",
  ] {
    #expect(throws: (any Error).self) { try BaseExecutionView.firmlinks(text) }
  }
}

@Test func executionHeaderIdentifiesOnlyArmExecutables() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let file = temporary.url.appendingPathComponent("mach-o")
  var header = Data(repeating: 0, count: 32)
  header.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe])
  header.replaceSubrange(4..<8, with: [12, 0, 0, 1])
  header[12] = 2
  try SafeFile.writeNew(header, to: file)
  #expect(try BaseExecutionView.isExecutable(file))
  header[12] = 6
  try SafeFile.replace(header, at: file)
  #expect(try !BaseExecutionView.isExecutable(file))
  var fat = Data(repeating: 0, count: 64)
  fat.replaceSubrange(0..<8, with: [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1])
  fat.replaceSubrange(8..<12, with: [1, 0, 0, 12])
  fat[19] = 32
  header[12] = 2
  fat.replaceSubrange(32..<64, with: header)
  try SafeFile.replace(fat, at: file)
  #expect(try BaseExecutionView.isExecutable(file))
  fat[19] = 33
  try SafeFile.replace(fat, at: file)
  #expect(throws: (any Error).self) { try BaseExecutionView.isExecutable(file) }
  try SafeFile.replace(Data("#!/bin/sh\n".utf8), at: file)
  #expect(try !BaseExecutionView.isExecutable(file))
}

@Test func baseTreeCopyBindsContentModesAndLinks() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let source = temporary.url.appendingPathComponent("source")
  try SafeFile.makeDirectory(source)
  try SafeFile.writeNew(Data("payload".utf8), to: source.appendingPathComponent("file"))
  #expect(symlink("file", source.appendingPathComponent("link").path) == 0)
  let entries = try BaseInputArchive.inventory(source)
  let output = temporary.url.appendingPathComponent("output")
  try BaseFileTree.copy(
    source, to: output, entries: entries, uid: getuid(), gid: getgid(), cancellation: nil)
  #expect(try BaseInputArchive.inventory(output) == entries)
  try BaseFileTree.requireOwnership(output, entries: entries, uid: getuid(), gid: getgid())
  #expect(throws: (any Error).self) {
    try BaseFileTree.requireOwnership(output, entries: entries, uid: UInt32.max, gid: getgid())
  }
  try SafeFile.replace(Data("changed".utf8), at: source.appendingPathComponent("file"))
  #expect(throws: (any Error).self) {
    try BaseFileTree.copy(
      source, to: temporary.url.appendingPathComponent("bad"), entries: entries,
      uid: getuid(), gid: getgid(), cancellation: nil)
  }
}

@Test func journalRequiresExactNegativeControlStatus() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("journal"), operation: "negative-controls")
  try journal.run("expected-denial", NativeCommand("/usr/bin/false"), expectedExitCodes: [1])
  #expect(journal.record.commands.last?.expectedExitCodes == [1])
  #expect(journal.record.commands.last?.error == nil)
  #expect(throws: (any Error).self) {
    try journal.run("unexpected-success", NativeCommand("/usr/bin/true"), expectedExitCodes: [1])
  }
  #expect(throws: (any Error).self) {
    try journal.run(
      "not-an-exit", NativeCommand("/bin/sleep", arguments: ["30"], timeout: 0.05),
      expectedExitCodes: [0, 1])
  }
}

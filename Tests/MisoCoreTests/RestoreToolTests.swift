import Foundation
import Testing

@testable import MisoCore

@Test func restoreToolPreservesAuthenticatedSourceAndRejectsChangedExecutable() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("apfs_sealvolume")
  try Artifacts.copy(URL(fileURLWithPath: "/usr/bin/true"), to: source, maximumBytes: 1 << 20)
  let digest = try SafeFile.sha256(source)
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("operation"), operation: "test-restore-tool")
  let tool = try RestoreTool.prepare(source: source, sha256: digest, journal: journal)
  #expect(try SafeFile.sha256(source) == digest)
  #expect(tool.receipt.original.sha256 == digest)
  #expect(tool.receipt.executable.sha256 != digest)
  try AppleCode.validate(source)
  try AppleCode.validateLocalTool(tool.executable)
  #expect(throws: MisoError.self) { try AppleCode.validate(tool.executable) }
  try journal.run("execute-tool", tool.command(arguments: [], timeout: 10))
  let handle = try FileHandle(forWritingTo: tool.executable)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data([0]))
  try handle.close()
  #expect(throws: MisoError.self) {
    try journal.run("reject-changed-tool", tool.command(arguments: [], timeout: 10))
  }
}

@Test func restoreToolRejectsUnauthenticatedAndMismatchedInputs() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("operation"), operation: "test-restore-tool")
  let source = URL(fileURLWithPath: "/usr/bin/true")
  #expect(throws: MisoError.self) {
    try RestoreTool.prepare(
      source: source, sha256: String(repeating: "0", count: 64), journal: journal)
  }
  let unsigned = directory.url.appendingPathComponent("unsigned")
  try SafeFile.writeNew(Data("unsigned executable".utf8), to: unsigned)
  #expect(throws: MisoError.self) {
    try RestoreTool.prepare(source: unsigned, sha256: SafeFile.sha256(unsigned), journal: journal)
  }
  #expect(journal.record.commands.isEmpty)
}

@Test func localRestoreToolRejectsEntitlementsAndLinkedExecutables() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("operation"), operation: "test-restore-tool")
  let source = URL(fileURLWithPath: "/usr/bin/true")
  let tool = try RestoreTool.prepare(
    source: source, sha256: SafeFile.sha256(source), journal: journal)
  let link = directory.url.appendingPathComponent("linked-tool")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool.executable)
  #expect(throws: MisoError.self) {
    try journal.run(
      "reject-linked-tool",
      NativeCommand.localRestoreTool(link, sha256: tool.receipt.executable.sha256, arguments: []))
  }
  let entitlements = directory.url.appendingPathComponent("entitlements.plist")
  try SafeFile.writeNew(
    PropertyListSerialization.data(
      fromPropertyList: ["com.apple.security.get-task-allow": true], format: .xml, options: 0),
    to: entitlements)
  try journal.run(
    "sign-with-entitlements",
    NativeCommand(
      .codesign,
      arguments: [
        "--force", "--sign", "-", "--timestamp=none", "--entitlements", entitlements.path,
        tool.executable.path,
      ]))
  #expect(throws: MisoError.self) { try AppleCode.validateLocalTool(tool.executable) }
  #expect(throws: MisoError.self) {
    try journal.run(
      "reject-entitled-tool",
      NativeCommand.localRestoreTool(
        tool.executable, sha256: SafeFile.sha256(tool.executable), arguments: []))
  }
}

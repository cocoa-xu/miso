import Darwin
import Foundation
import Testing

@testable import MisoCore

private func withProcess<T>(_ body: (FileHandle, FileHandle, URL) throws -> T) throws -> T {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let output = directory.url.appendingPathComponent("stdout")
  let out = try SafeFile.create(output)
  let err = try SafeFile.create(directory.url.appendingPathComponent("stderr"))
  defer {
    try? out.close()
    try? err.close()
  }
  return try body(out, err, output)
}

@Test func nativeProcessPreservesArgumentsWithoutShellExpansion() throws {
  try withProcess { out, err, output in
    let value = "literal $HOME; $(false) `false`"
    let result = try NativeProcess.run(
      NativeCommand("/usr/bin/printf", arguments: ["%s", value]), stdout: out, stderr: err)
    #expect(result.succeeded)
    #expect(try SafeFile.read(output, limit: 1024) == Data(value.utf8))
  }
}

@Test func nativeProcessReportsExitAndSpawnFailure() throws {
  try withProcess { out, err, _ in
    let result = try NativeProcess.run(NativeCommand("/usr/bin/false"), stdout: out, stderr: err)
    #expect(result.exitCode == 1 && !result.succeeded)
    #expect(throws: (any Error).self) {
      try NativeProcess.run(NativeCommand("/does-not-exist/miso-test"), stdout: out, stderr: err)
    }
  }
}

@Test func nativeProcessUsesAChildWorkingDirectoryWithoutChangingTheParent() throws {
  let parent = FileManager.default.currentDirectoryPath
  try withProcess { out, err, output in
    let directory = output.deletingLastPathComponent().appendingPathComponent("space and $literal")
    try SafeFile.makeDirectory(directory)
    let result = try NativeProcess.run(
      NativeCommand("/bin/pwd", workingDirectory: directory), stdout: out, stderr: err)
    #expect(result.succeeded)
    #expect(
      String(decoding: try SafeFile.read(output, limit: 4096), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines) == directory.path)
    #expect(FileManager.default.currentDirectoryPath == parent)
    let command = try NativeCommand("/bin/pwd", workingDirectory: directory)
    try FileManager.default.removeItem(at: directory)
    #expect(throws: MisoError.self) {
      try NativeProcess.run(command, stdout: out, stderr: err)
    }
  }
}

@Test func nativeProcessRejectsLinkedWorkingDirectories() throws {
  try withProcess { _, _, output in
    let directory = output.deletingLastPathComponent()
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    #expect(throws: MisoError.self) { try NativeCommand("/bin/pwd", workingDirectory: link) }
    #expect(throws: MisoError.self) { try NativeCommand("/bin/pwd", workingDirectory: output) }
  }
}

@Test func nativeProcessTerminatesTimedOutGroup() throws {
  try withProcess { out, err, _ in
    let command = try NativeCommand(
      "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30 & wait"], timeout: 0.15)
    let result = try NativeProcess.run(command, stdout: out, stderr: err)
    #expect(result.timedOut && !result.succeeded && result.signal == SIGKILL)
    #expect(result.elapsedSeconds < 5)
  }
}

@Test func nativeProcessCancellation() throws {
  let token = try CancellationToken()
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
  try withProcess { out, err, _ in
    let result = try NativeProcess.run(
      NativeCommand("/bin/sleep", arguments: ["30"]), stdout: out, stderr: err, cancellation: token)
    #expect(result.cancelled && !result.timedOut && !result.succeeded)
    #expect(result.elapsedSeconds < 5)
    let rejected = try NativeProcess.run(
      NativeCommand("/usr/bin/true"), stdout: out, stderr: err, cancellation: token)
    #expect(rejected.cancelled && rejected.exitCode == -1)
  }
}

@Test func journalPersistsSuccessFailureAndRedaction() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("operation"), operation: "test-operation")
  let command = try NativeCommand(
    "/usr/bin/printf", arguments: ["%s", "secret-value"], redactedArguments: [1],
    workingDirectory: directory.url)
  _ = try journal.run("redacted", command)
  let captured = try SafeFile.read(
    journal.output.appendingPathComponent("journal.json"), limit: 1 << 20)
  #expect(!String(decoding: captured, as: UTF8.self).contains("secret-value"))
  #expect(throws: (any Error).self) {
    try journal.perform {
      _ = try journal.run("failure", NativeCommand("/usr/bin/false"))
      return ["passed": true]
    }
  }
  #expect(journal.record.status == .failed && journal.record.commands.count == 2)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let stored = try decoder.decode(
    ExecutionJournal.Record.self,
    from: SafeFile.read(journal.output.appendingPathComponent("journal.json"), limit: 1 << 20))
  #expect(stored.status == .failed && stored.commands.last?.result?.exitCode == 1)
  #expect(stored.commands.first?.workingDirectory == directory.url.path)
  let success = try ExecutionJournal(
    output: directory.url.appendingPathComponent("success"), operation: "success")
  _ = try success.perform { ["passed": true] }
  #expect(success.record.status == .complete)
}

@Test func cleanupMayRunAfterCancellation() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("operation"), operation: "cleanup")
  journal.cancellation.cancel()
  #expect(throws: (any Error).self) { try journal.run("normal", NativeCommand("/usr/bin/true")) }
  _ = try journal.run("cleanup", NativeCommand("/usr/bin/true"), cleanup: true)
  #expect(throws: (any Error).self) { try journal.finish(["passed": true]) }
}

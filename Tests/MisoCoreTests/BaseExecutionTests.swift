import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func executionStrategiesFollowReviewedTargetProfiles() throws {
  #expect(
    try BaseExecutionView.Mode.select(.init(version: "15.6.1", build: "24G90")) == .mountedSystem)
  #expect(
    try BaseExecutionView.Mode.select(.init(version: "26.6.2", build: "25G83")) == .copiedTools)
  #expect(
    try BaseExecutionView.Mode.select(.init(version: "27.0", build: "26A428")) == .copiedTools)
  for target in [
    MacOSRelease(version: "26.6.2", build: "unknown"), .init(version: "28.0", build: "future"),
  ] {
    #expect(throws: (any Error).self) { try BaseExecutionView.Mode.select(target) }
  }
}

@Test func goldenGateUsesTemporaryToolsAcrossSupportedBuilds() throws {
  for target in [
    MacOSRelease(version: "27.0", build: "26A428"), .init(version: "27.0.1", build: "26A434"),
  ] {
    #expect(try BaseExecutionView.Mode.select(target) == .copiedTools)
  }
}

@Test func executionLinksHaveExplicitModesAndPreserveTargets() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  for mode: mode_t in [0o700, 0o755, 0o555] {
    let link = temporary.url.appendingPathComponent("link-\(mode)")
    try BaseExecutionView.createLink("/System/Volumes/Data/Users", at: link, mode: mode)
    #expect(try FileMetadata.inspect(link).st_mode & 0o777 == mode)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        == "/System/Volumes/Data/Users")
  }
}

@Test func executionLinksRejectUnsafeModesAndExistingFiles() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let file = temporary.url.appendingPathComponent("existing")
  let bytes = Data("preserved".utf8)
  try SafeFile.writeNew(bytes, to: file)
  #expect(throws: (any Error).self) { try BaseExecutionView.createLink("/target", at: file) }
  #expect(try SafeFile.read(file, limit: 64) == bytes)
  let unsafe = temporary.url.appendingPathComponent("unsafe")
  #expect(throws: (any Error).self) {
    try BaseExecutionView.createLink("/target", at: unsafe, mode: 0o777)
  }
  #expect(!FileManager.default.fileExists(atPath: unsafe.path))
}

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

@Test func signedExecutionRenewalPreservesBytesAndRejectsSharedFiles() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let file = temporary.url.appendingPathComponent("tool")
  let bytes = Data("signed execution fixture".utf8)
  try SafeFile.writeNew(bytes, to: file)
  #expect(chmod(file.path, 0o755) == 0)
  let original = try FileMetadata.inspect(file)
  try BaseExecutionView.renewSignedExecutable(file)
  let renewed = try FileMetadata.inspect(file)
  #expect(renewed.st_ino != original.st_ino)
  #expect(renewed.st_mode == original.st_mode)
  #expect(try SafeFile.read(file, limit: 100) == bytes)
  let alias = temporary.url.appendingPathComponent("alias")
  #expect(link(file.path, alias.path) == 0)
  #expect(throws: MisoError.self) { try BaseExecutionView.renewSignedExecutable(file) }
  #expect(try FileMetadata.inspect(file).st_ino == renewed.st_ino)
}

@Test func executionSigningExcludesAppleDeveloperTools() {
  for path in [
    "bin/sh", "sbin/mount", "usr/bin/clang", "usr/sbin/pkgutil", "usr/libexec/path_helper",
  ] {
    #expect(BaseExecutionView.requiresLocalSignature(path))
  }
  for path in [
    "Library/Developer/CommandLineTools/usr/bin/clang",
    "Library/Developer/CommandLineTools/usr/libexec/git-core/git",
    "Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
    "System/Library/Frameworks/Foundation.framework/Foundation",
  ] {
    #expect(!BaseExecutionView.requiresLocalSignature(path))
  }
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
  try journal.run(
    "exec-denied", NativeCommand("/bin/sh", arguments: ["-c", "exit 126"]),
    expectedExitCodes: [1, 126])
  for status in [0, 125, 127] {
    #expect(throws: (any Error).self) {
      try journal.run(
        "not-privilege-denial", NativeCommand("/bin/sh", arguments: ["-c", "exit \(status)"]),
        expectedExitCodes: [1, 126])
    }
  }
  #expect(throws: (any Error).self) {
    try journal.run(
      "not-an-exit", NativeCommand("/bin/sleep", arguments: ["30"], timeout: 0.05),
      expectedExitCodes: [0, 1])
  }
}

@Test func journalAllocatesUniquePathsForRepeatedPackageOperations() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("journal"),
    operation: "base-bottles")
  let first = try journal.run("install-bottle", NativeCommand("/usr/bin/true"))
  let second = try journal.run("install-bottle", NativeCommand("/usr/bin/true"))
  #expect(first != second)
  #expect(journal.record.commands.map(\.name) == ["install-bottle", "install-bottle"])
}

@Test func journalMeasuresSuccessfulAndFailedNativeWork() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("journal"),
    operation: "base-timing")
  #expect(try journal.measure("successSeconds") { 42 } == 42)
  #expect(throws: MisoError.self) {
    try journal.measure("failureSeconds") { throw MisoError.invalid("Expected failure") }
  }
  #expect(journal.record.metadata["successSeconds"] != nil)
  #expect(journal.record.metadata["failureSeconds"] != nil)
  #expect(journal.record.status == .running)
}

@Test func guestInventoryDoesNotResolveAbsoluteLinksOnTheHost() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  let prefix = try volume.path("opt/homebrew", createParents: true)
  try SafeFile.makeDirectory(prefix)
  let absolute = "/opt/homebrew/etc/ca-certificates/cert.pem"
  #expect(symlink(absolute, prefix.appendingPathComponent("absolute").path) == 0)
  #expect(symlink("../../Library/SDK", prefix.appendingPathComponent("relative").path) == 0)
  let inventory = try BaseFileTree.inventory(volume, path: "opt/homebrew")
  #expect(inventory.first { $0.path == "absolute" }?.link == absolute)
  #expect(inventory.first { $0.path == "relative" }?.link == "../../Library/SDK")
  #expect(throws: (any Error).self) { try BaseInputArchive.inventory(prefix) }
  #expect(symlink("../../../outside", prefix.appendingPathComponent("escape").path) == 0)
  #expect(throws: (any Error).self) { try BaseFileTree.inventory(volume, path: "opt/homebrew") }
}

@Test func executionToolAuthenticationHandlesSealedSystemResourceRules() throws {
  let executable = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
  #expect(try BaseExecutionView.isExecutable(executable))
  try AppleCode.validate(executable, scope: .executable)
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let copied = temporary.url.appendingPathComponent("copied-tool")
  try Artifacts.copy(
    executable, to: copied, maximumBytes: UInt64(try FileMetadata.inspect(executable).st_size))
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("signing"), operation: "test-execution-tool")
  try journal.run(
    "remove-signature", NativeCommand(.codesign, arguments: ["--remove-signature", copied.path]))
  try journal.run(
    "sign-tool",
    NativeCommand(.codesign, arguments: ["--sign", "-", "--timestamp=none", copied.path]))
  try BaseExecutionView.renewSignedExecutable(copied)
  try AppleCode.validateLocalTool(copied, scope: .executable)
  let handle = try SafeFile.openRegular(copied, writable: true)
  try handle.write(contentsOf: Data([0]))
  try handle.close()
  #expect(throws: MisoError.self) { try AppleCode.validateLocalTool(copied, scope: .executable) }
  #expect(throws: MisoError.self) { try AppleCode.validate(temporary.url, scope: .executable) }
  let file = temporary.url.appendingPathComponent("unsigned")
  try SafeFile.writeNew(Data("untrusted".utf8), to: file)
  #expect(throws: MisoError.self) { try AppleCode.validate(file, scope: .executable) }
  #expect(throws: MisoError.self) { try AppleCode.validateLocalTool(file, scope: .executable) }
}

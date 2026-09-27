import Darwin
import Foundation
import Testing

@testable import MisoCore

private func archiveView(_ root: URL) throws -> URL {
  let volume = try GuestVolume(root)
  let directory = try volume.path(ArchiveToolAdapter.directory, createParents: true)
  try SafeFile.makeDirectory(directory)
  var header = Data(repeating: 0, count: 32)
  header.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe])
  header.replaceSubrange(4..<8, with: [12, 0, 0, 1])
  header[12] = 2
  try SafeFile.writeNew(header, to: directory.appendingPathComponent("libtool"))
  #expect(symlink("libtool", directory.appendingPathComponent("ranlib").path) == 0)
  return directory
}

@Test func archiveAdaptersRestoreBothToolsAndRejectReinstallation() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let directory = try archiveView(temporary.url)
  let original = try SafeFile.sha256(directory.appendingPathComponent("libtool"))
  let state = try ArchiveToolAdapter.install(temporary.url)
  for name in ["libtool", "ranlib"] {
    #expect(try SafeFile.sha256(directory.appendingPathComponent(name)) == state.wrapperSHA256)
    #expect(
      try FileMetadata.inspect(directory.appendingPathComponent(name)).st_mode & 0o777 == 0o755)
  }
  #expect(throws: (any Error).self) { try ArchiveToolAdapter.install(temporary.url) }
  try ArchiveToolAdapter.restore(state)
  try ArchiveToolAdapter.restore(state)
  #expect(try SafeFile.sha256(directory.appendingPathComponent("libtool")) == original)
  #expect(
    try FileManager.default.destinationOfSymbolicLink(
      atPath: directory.appendingPathComponent("ranlib").path) == "libtool")
  #expect(
    !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".miso-libtool").path))
}

@Test func archiveAdapterRestoresWhenBuildThrows() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let directory = try archiveView(temporary.url)
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("journal"), operation: "archive-control")
  #expect(throws: MisoError.self) {
    try ArchiveToolAdapter.withView(
      temporary.url, target: .init(version: "26.6.2", build: "25G83"), journal: journal
    ) {
      throw MisoError.invalid("Expected control failure")
    }
  }
  #expect(journal.record.metadata["archiveToolAdapterRestored"] == .bool(true))
  #expect(try BaseExecutionView.isExecutable(directory.appendingPathComponent("libtool")))
}

@Test func archiveAdapterPreservesUnexpectedReplacementAndOriginalBackup() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let directory = try archiveView(temporary.url)
  let state = try ArchiveToolAdapter.install(temporary.url)
  let replacement = Data("unexpected replacement".utf8)
  try SafeFile.replace(replacement, at: directory.appendingPathComponent("libtool"))
  #expect(throws: (any Error).self) { try ArchiveToolAdapter.restore(state) }
  #expect(
    try SafeFile.read(directory.appendingPathComponent("libtool"), limit: 1024) == replacement)
  #expect(
    try SafeFile.sha256(directory.appendingPathComponent(".miso-libtool")) == state.toolSHA256)
}

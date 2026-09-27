import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func readOnlyImageScopeReleasesBackingFileLock() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let image = directory.url.appendingPathComponent("disk.img")
  try SafeFile.writeNew(Data([0]), to: image)
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("operation"), operation: "image-lock")
  let file = try SafeFile.openRegular(image)
  defer { try? file.close() }
  func audit() throws {
    let session = try DiskImageSession(image: image, readOnly: true, journal: journal)
    withExtendedLifetime(session) {
      #expect(flock(file.fileDescriptor, LOCK_EX | LOCK_NB) != 0)
      #expect(errno == EWOULDBLOCK)
    }
  }
  try audit()
  #expect(flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
  #expect(flock(file.fileDescriptor, LOCK_UN) == 0)
}

@Test func baseArchiveIsPortableAndDetectsMissingChangedAndExtraInputs() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("source")
  try SafeFile.makeDirectory(source)
  let executable = source.appendingPathComponent("tool")
  try SafeFile.writeNew(Data("payload".utf8), to: executable)
  #expect(chmod(executable.path, 0o755) == 0)
  try SafeFile.writeNew(Data(), to: source.appendingPathComponent("empty"))
  #expect(symlink("tool", source.appendingPathComponent("link").path) == 0)
  let spec = BaseInputArchive.Specification(
    schemaVersion: 1, target: RestoreProfile.supported[0].release,
    resources: [.init(name: "tools", path: "source", origin: "https://example.com/tools")])
  let specification = directory.url.appendingPathComponent("spec.json")
  try SafeFile.writeNew(JSON.encode(spec), to: specification)
  let output = directory.url.appendingPathComponent("archive")
  let result = try BaseInputArchive.create(specification: specification, output: output)
  #expect(result.entries == 4 && !result.completeBaseInputs && !result.vmStarted)
  let moved = directory.url.appendingPathComponent("moved")
  try FileManager.default.moveItem(at: output, to: moved)
  try FileManager.default.removeItem(at: source)
  #expect(try BaseInputArchive.verify(moved).archiveSHA256 == result.archiveSHA256)
  let copy = moved.appendingPathComponent("resources/tools/tool")
  try SafeFile.replace(Data("changed".utf8), at: copy)
  #expect(throws: (any Error).self) { try BaseInputArchive.verify(moved) }
  try SafeFile.replace(Data("payload".utf8), at: copy)
  #expect(chmod(copy.path, 0o755) == 0)
  _ = try BaseInputArchive.verify(moved)
  let extra = moved.appendingPathComponent("resources/tools/extra")
  try SafeFile.writeNew(Data(), to: extra)
  #expect(throws: (any Error).self) { try BaseInputArchive.verify(moved) }
  try FileManager.default.removeItem(at: extra)
  try FileManager.default.removeItem(at: copy)
  #expect(throws: (any Error).self) { try BaseInputArchive.verify(moved) }
}

@Test func baseArchiveRejectsEscapingLinksSetIDFilesAndNestedOutput() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("source")
  try SafeFile.makeDirectory(source)
  let link = source.appendingPathComponent("escape")
  #expect(symlink("../../outside", link.path) == 0)
  #expect(throws: (any Error).self) { try BaseInputArchive.inventory(source) }
  try FileManager.default.removeItem(at: link)
  try SafeFile.writeNew(Data([1]), to: link)
  #expect(chmod(link.path, 0o4755) == 0)
  #expect(throws: (any Error).self) { try BaseInputArchive.inventory(source) }
  let spec = BaseInputArchive.Specification(
    schemaVersion: 1, target: RestoreProfile.supported[0].release,
    resources: [.init(name: "tools", path: source.path, origin: nil)])
  let specification = directory.url.appendingPathComponent("spec.json")
  try SafeFile.writeNew(JSON.encode(spec), to: specification)
  #expect(throws: (any Error).self) {
    try BaseInputArchive.create(
      specification: specification, output: source.appendingPathComponent("nested"))
  }
}

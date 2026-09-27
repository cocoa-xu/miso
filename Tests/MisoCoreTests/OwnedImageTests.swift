import Foundation
import Testing

@testable import MisoCore

@Test func writableImageSessionsRequireAnOperationOwnedClone() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let source = temporary.url.appendingPathComponent("source.img")
  try SafeFile.writeNew(Data("fixture".utf8), to: source)
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("operation"), operation: "ownership-test")
  #expect(throws: (any Error).self) {
    try DiskImageSession(image: source, readOnly: false, journal: journal)
  }
  let readOnly = try DiskImageSession(image: source, readOnly: true, journal: journal)
  #expect(readOnly.readOnly)
  let sibling = temporary.url.appendingPathComponent("operation-sibling")
  try SafeFile.makeDirectory(sibling)
  let siblingImage = sibling.appendingPathComponent("disk.img")
  try Artifacts.clone(source, to: siblingImage)
  #expect(throws: (any Error).self) {
    try DiskImageSession(image: siblingImage, readOnly: false, journal: journal)
  }
  let owned = journal.output.appendingPathComponent("disk.img")
  try Artifacts.clone(source, to: owned)
  let writable = try DiskImageSession(image: owned, readOnly: false, journal: journal)
  #expect(!writable.readOnly)
  #expect(try SafeFile.sha256(owned) == SafeFile.sha256(source))
}

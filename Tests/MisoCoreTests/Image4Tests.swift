import CryptoKit
import Foundation
import Testing

@testable import MisoCore

private func payload(_ content: Data) -> Data {
  DER.encode(
    0x30,
    DER.encode(0x16, Data("IM4P".utf8)) + DER.encode(0x16, Data("test".utf8))
      + DER.encode(0x16, Data()) + DER.encode(4, content))
}

private func manifest(for payload: Data) throws -> Data {
  let digest = try Image4.property("DGST", value: DER.encode(4, Data(SHA384.hash(data: payload))))
  let component = try Image4.property("test", value: DER.encode(0x31, digest))
  let body = try Image4.property("MANB", value: DER.encode(0x31, component))
  return DER.encode(
    0x30,
    DER.encode(0x16, Data("IM4M".utf8)) + DER.integer(0)
      + DER.encode(0x31, body) + DER.encode(4, Data()) + DER.encode(0x30, Data()))
}

@Test func image4NativePayloadAndManifest() throws {
  let bytes = Data("fixture".utf8)
  let original = payload(bytes)
  let ticket = try manifest(for: original)
  #expect(try Image4.unwrap(original) == bytes)
  let renamed = try Image4.retype(original, type: "news")
  #expect(try Image4.payloadFields(renamed)[1].content == Data("news".utf8))
  #expect(try Image4.unwrap(renamed) == bytes)
  try Image4.verifyDigest(payload: original, ticket: ticket, type: "test")
  #expect(throws: (any Error).self) {
    try Image4.verifyDigest(payload: renamed, ticket: ticket, type: "test")
  }
  let stitched = try DER.nodes(
    DER.one(Image4.stitch(payload: original, ticket: ticket), tag: 0x30).content)
  #expect(stitched.count == 3)
  #expect(stitched[1].encoded == original && stitched[2].content == ticket)
}

@Test func image4RejectsDuplicateAndInconsistentProperties() throws {
  let one = try Image4.property("TEST", value: DER.integer(1))
  #expect(throws: (any Error).self) { try Image4.properties(DER.encode(0x31, one + one)) }
  let encodedName = Data("TEST".utf8)
  var inconsistent = one
  let range = try #require(inconsistent.range(of: encodedName))
  inconsistent.replaceSubrange(range, with: Data("NOPE".utf8))
  #expect(throws: (any Error).self) { try Image4.properties(DER.encode(0x31, inconsistent)) }
}

@Test(arguments: [
  Data([4, 0x80]), Data([4, 0x81, 1, 0]), Data([4, 2, 1]), Data([0xff, 0x80, 1, 0]),
  Data([0x1f, 1, 0]),
])
func derRejectsNoncanonicalAndTruncatedInput(_ data: Data) {
  #expect(throws: (any Error).self) { try DER.nodes(data) }
}

@Test func derLengthsAndIntegers() throws {
  for size in [0, 1, 127, 128, 255, 256, 8192] {
    let data = Data(repeating: 19, count: size)
    #expect(try DER.one(DER.encode(4, data), tag: 4).content == data)
  }
  #expect(try DER.one(DER.integer(128)).content == Data([0, 128]))
  #expect(
    try DER.one(DER.integer(UInt64.max)).content == Data([0] + Array(repeating: 255, count: 8)))
}

@Test func image4SnapshotName() throws {
  var data = Data(count: 208)
  for (offset, value) in [(0, 2), (4, 0), (8, 1), (12, 32)] { data.put(UInt32(value), at: offset) }
  data.replaceSubrange(16..<48, with: Data(repeating: 0xab, count: 32))
  #expect(
    try Image4.snapshotName(authBlob: data) == "com.apple.os.update-"
      + String(repeating: "AB", count: 32))
  #expect(throws: (any Error).self) { try Image4.snapshotName(authBlob: Data(data.dropLast())) }
}

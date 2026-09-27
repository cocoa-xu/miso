import AppleArchive
import CryptoKit
import Foundation
import System
import Testing

@testable import MisoCore

private func authEntry(_ name: String, _ value: Data) -> Data {
  var result = Data(count: 4)
  result += Data(name.utf8) + Data([0]) + value
  result.put(UInt32(result.count), at: 0)
  return result
}

private func metadata(_ fields: Data) throws -> AEA.Metadata {
  var header = Data("AEA1".utf8) + Data(count: 8)
  header.put(UInt32(1), at: 4)
  header.put(UInt32(fields.count), at: 8)
  return try AEA.Metadata(header: header, authenticatedData: fields)
}

private func encryptedFixture(
  _ data: Data, key: SymmetricKey, output: URL,
  authData: Data? = nil
) throws {
  let handle = try SafeFile.create(output)
  defer { try? handle.close() }
  let file = try #require(
    ArchiveByteStream.fileStream(
      fd: FileDescriptor(rawValue: handle.fileDescriptor), automaticClose: false))
  defer { try? file.close() }
  let context = ArchiveEncryptionContext(
    profile: .hkdf_sha256_aesctr_hmac__symmetric__none, compressionAlgorithm: .lzfse)
  try context.setSymmetricKey(key)
  context.authData = authData
  let stream = try #require(
    ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context, threadCount: 2))
  defer { try? stream.close() }
  let count = try data.withUnsafeBytes { try stream.write(from: $0) }
  #expect(count == data.count)
  try stream.close()
  try file.close()
  try handle.synchronize()
}

@Test func aeaNativeStreamingRoundTrip() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let key = SymmetricKey(size: .bits256)
  let source = directory.url.appendingPathComponent("payload.aea")
  let output = directory.url.appendingPathComponent("decoded")
  let data = Data(repeating: 0x5a, count: (3 << 20) + 7)
  try encryptedFixture(data, key: key, output: source)
  let result = try EncryptedArchive.decrypt(source: source, output: output, key: key)
  #expect(result.bytes == data.count)
  #expect(result.sha256 == SafeFile.sha256(data))
  #expect(try SafeFile.read(output, limit: data.count) == data)
  #expect(throws: (any Error).self) {
    try EncryptedArchive.decrypt(source: source, output: output, key: key)
  }
}

@Test func aeaRejectsInvalidKeysLimitsAndCancellation() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("payload.aea")
  let output = directory.url.appendingPathComponent("decoded")
  let key = SymmetricKey(size: .bits256)
  try encryptedFixture(Data(repeating: 7, count: 8192), key: key, output: source)
  #expect(throws: (any Error).self) {
    try EncryptedArchive.decrypt(source: source, output: output, key: .init(size: .bits256))
  }
  #expect(throws: (any Error).self) {
    try EncryptedArchive.decrypt(source: source, output: output, key: key, maximumOutputBytes: 8191)
  }
  let token = try CancellationToken()
  token.cancel()
  #expect(throws: CancellationError.self) {
    try EncryptedArchive.decrypt(source: source, output: output, key: key, cancellation: token)
  }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func aeaRejectsTruncationAndTampering() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let original = directory.url.appendingPathComponent("original.aea")
  let key = SymmetricKey(size: .bits256)
  try encryptedFixture(Data(repeating: 19, count: 4 << 20), key: key, output: original)
  let bytes = try SafeFile.read(original, limit: 8 << 20)
  for (name, data) in [
    ("truncated", Data(bytes.dropLast(100))),
    ("corrupt", bytes.dropLast() + Data([bytes.last! ^ 255])),
  ] {
    let source = directory.url.appendingPathComponent(name)
    try SafeFile.writeNew(data, to: source)
    #expect(throws: (any Error).self) {
      try EncryptedArchive.decrypt(
        source: source, output: source.appendingPathExtension("out"), key: key)
    }
  }
}

@Test func aeaHPKEKeyResolutionIsNative() async throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let privateKey = P256.KeyAgreement.PrivateKey()
  let pem = Data(privateKey.pemRepresentation.utf8)
  let keyData = Data((0..<32).map(UInt8.init))
  var sender = try HPKE.Sender(
    recipientKey: privateKey.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: Data())
  let response = try JSONSerialization.data(withJSONObject: [
    "enc-request": sender.encapsulatedKey.base64EncodedString(),
    "wrapped-key": try sender.seal(keyData).base64EncodedString(),
  ])
  let auth = authEntry("com.apple.wkms.fcs-response", response)
  let parsed = try metadata(auth)
  #expect(try parsed.symmetricKey(privateKeyPEM: pem) == keyData)
  #expect(throws: (any Error).self) {
    try parsed.symmetricKey(
      privateKeyPEM: Data(P256.KeyAgreement.PrivateKey().pemRepresentation.utf8))
  }
  let source = directory.url.appendingPathComponent("payload.aea")
  let pemURL = directory.url.appendingPathComponent("recipient.pem")
  let output = directory.url.appendingPathComponent("decoded")
  let data = Data("native AEA fixture".utf8)
  try encryptedFixture(data, key: SymmetricKey(data: keyData), output: source, authData: auth)
  try SafeFile.writeNew(pem, to: pemURL)
  let resolved = try await AEA.decryptionKey(source, privateKeyPEM: pemURL)
  let receipt = try EncryptedArchive.decrypt(source: source, output: output, key: resolved)
  #expect(receipt.sha256 == SafeFile.sha256(data))
}

@Test(arguments: [
  "http://example.apple.com/key", "https://apple.com.evil.test/key",
  "https://example.apple.com@evil.test/key", "https://a.apple.com:444/key",
  "https://a.apple.com/key#fragment",
])
func aeaRejectsUntrustedKeyEndpoint(_ url: String) throws {
  let value = try metadata(authEntry("com.apple.wkms.fcs-key-url", Data(url.utf8)))
  #expect(throws: (any Error).self) { try value.keyURL }
}

@Test func aeaMetadataBoundsAndDuplicates() throws {
  let entry = authEntry(
    "com.apple.wkms.fcs-key-url", Data("https://wkms-public.apple.com/fcs-keys/key".utf8))
  #expect(try metadata(entry).keyURL.host == "wkms-public.apple.com")
  #expect(throws: (any Error).self) { try metadata(entry + entry) }
  #expect(throws: (any Error).self) { try metadata(Data(entry.dropLast())) }
  #expect(throws: (any Error).self) { try metadata(Data()) }
}

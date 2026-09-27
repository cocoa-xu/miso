import AppleArchive
import CryptoKit
import Foundation
import System

public enum EncryptedArchive {
  public struct Receipt: Encodable, Sendable {
    public let bytes: UInt64
    public let sha256: String
  }

  public static func decrypt(
    source: URL, output: URL, key: SymmetricKey,
    maximumOutputBytes: UInt64 = 128 << 30,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard key.bitCount == 256, maximumOutputBytes > 0, maximumOutputBytes <= 1 << 40 else {
      throw MisoError.invalid("Invalid AEA key or output limit")
    }
    try cancellation?.check()
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let sourceSize = try SafeFile.size(input)
    guard
      let file = ArchiveByteStream.fileStream(
        fd: FileDescriptor(rawValue: input.fileDescriptor), automaticClose: false)
    else {
      throw MisoError.invalid("Cannot open AEA stream")
    }
    defer { try? file.close() }
    guard let context = ArchiveEncryptionContext(from: file),
      context.profile == .hkdf_sha256_aesctr_hmac__symmetric__none
    else {
      throw MisoError.unsupported("AEA encryption profile")
    }
    try context.setSymmetricKey(key)
    guard context.decryptAttributes(), context.rawSize > 0,
      UInt64(context.rawSize) <= maximumOutputBytes
    else {
      throw MisoError.invalid("AEA authentication or output-size validation failed")
    }
    guard
      let decrypted = ArchiveByteStream.decryptionStream(
        readingFrom: file, encryptionContext: context, threadCount: 2)
    else {
      throw MisoError.invalid("Cannot create AEA decryption stream")
    }
    defer { try? decrypted.close() }
    let destination = try SafeFile.create(output)
    defer { try? destination.close() }
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
    defer { buffer.deallocate() }
    var digest = SHA256()
    var written: UInt64 = 0
    while true {
      try cancellation?.check()
      let count = try decrypted.read(into: buffer)
      guard count >= 0, count <= buffer.count, UInt64(count) <= maximumOutputBytes - written else {
        throw MisoError.invalid("AEA output exceeds its limit")
      }
      if count == 0 { break }
      try autoreleasepool {
        let bytes = Data(bytesNoCopy: buffer.baseAddress!, count: count, deallocator: .none)
        try destination.write(contentsOf: bytes)
        digest.update(data: bytes)
      }
      written += UInt64(count)
    }
    try decrypted.close()
    try cancellation?.check()
    guard written == UInt64(context.rawSize), try SafeFile.size(input) == sourceSize else {
      throw MisoError.invalid("AEA output size mismatch or changed source")
    }
    try destination.synchronize()
    return Receipt(bytes: written, sha256: SafeFile.hex(digest.finalize()))
  }
}

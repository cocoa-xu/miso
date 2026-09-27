import Foundation
import Testing

@testable import MisoCore

@Test func hexadecimalEncodingPreservesEveryByteAndLeadingZero() throws {
  let bytes = (0...255).map(UInt8.init)
  #expect(SafeFile.hex(bytes) == bytes.map { String(format: "%02x", $0) }.joined())
  #expect(SafeFile.hex([UInt8]()) == "")
  #expect(SafeFile.hex([0, 1, 15, 16, 127, 128, 254, 255]) == "00010f107f80feff")
  #expect(
    SafeFile.sha256(Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

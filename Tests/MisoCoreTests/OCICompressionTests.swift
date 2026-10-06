import Foundation
import Testing

@testable import MisoCore

@Test func ociLZ4StreamsInteroperateWithFoundationAndRejectOversizedOutput() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let bytes = Data(repeating: 97, count: (2 << 20) + 73) + Data((0...255).map(UInt8.init))
  let source = temporary.url.appendingPathComponent("raw")
  try SafeFile.writeNew(bytes, to: source)
  let input = try SafeFile.openRegular(source)
  defer { try? input.close() }
  var encoded = Data()
  let compressed = try OCICompression.process(
    input: input, bytes: UInt64(bytes.count), encoding: true,
    maximumOutput: UInt64(bytes.count + (1 << 20)), cancellation: nil
  ) { encoded.append($0) }
  #expect(try (encoded as NSData).decompressed(using: .lz4) as Data == bytes)
  #expect(compressed.inputDigest == "sha256:" + SafeFile.sha256(bytes))
  #expect(compressed.outputDigest == "sha256:" + SafeFile.sha256(encoded))
  let file = temporary.url.appendingPathComponent("compressed")
  let foundation = try (bytes as NSData).compressed(using: .lz4) as Data
  try SafeFile.writeNew(foundation, to: file)
  let stream = try SafeFile.openRegular(file)
  defer { try? stream.close() }
  var decoded = Data()
  let result = try OCICompression.process(
    input: stream, bytes: UInt64(foundation.count), encoding: false,
    maximumOutput: UInt64(bytes.count), cancellation: nil
  ) { decoded.append($0) }
  #expect(decoded == bytes)
  #expect(result.outputBytes == UInt64(bytes.count))
  #expect(result.outputDigest == compressed.inputDigest)
  try stream.seek(toOffset: 0)
  #expect(throws: MisoError.self) {
    try OCICompression.process(
      input: stream, bytes: UInt64(foundation.count), encoding: false,
      maximumOutput: UInt64(bytes.count - 1), cancellation: nil
    ) { _ in }
  }
  try stream.seek(toOffset: 0)
  #expect(throws: MisoError.self) {
    try OCICompression.process(
      input: stream, bytes: UInt64(foundation.count - 1), encoding: false,
      maximumOutput: UInt64(bytes.count), cancellation: nil
    ) { _ in }
  }
}

@Test func transferRateUsesRecentTrafficAndDecaysWhileIdle() {
  var rate = TransferRate(now: 0)
  rate.record(1000, now: 10)
  #expect(rate.perSecond(now: 10) == 100)
  rate.record(0, now: 70)
  #expect(rate.perSecond(now: 70) == 0)
  rate.record(6000, now: 80)
  #expect(rate.perSecond(now: 80) == 100)
  rate.record(0, now: 140)
  #expect(rate.perSecond(now: 140) == 0)
}

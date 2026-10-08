import ArchiveKit
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

@Test func ociZstdStreamsRejectTruncationTrailingDataAndOversizedOutput() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let bytes = Data(repeating: 0, count: 2 << 20) + Data((0..<131_079).map { UInt8($0 % 251) })
  let encoder = try ZstdStream(encoding: true)
  var encoded = Data()
  try encoder.process(bytes.prefix(77), final: false) { encoded.append($0) }
  try encoder.process(bytes.dropFirst(77), final: true) { encoded.append($0) }
  #expect(encoded.prefix(4) == Data([0x28, 0xb5, 0x2f, 0xfd]))
  let archive = try #require(archive_read_new())
  defer { archive_read_free(archive) }
  #expect(archive_read_support_filter_zstd(archive) == ARCHIVE_OK)
  #expect(archive_read_support_format_raw(archive) == ARCHIVE_OK)
  encoded.withUnsafeBytes { input in
    #expect(archive_read_open_memory(archive, input.baseAddress, input.count) == ARCHIVE_OK)
    var entry: OpaquePointer?
    #expect(archive_read_next_header(archive, &entry) == ARCHIVE_OK)
    var output = Data(count: bytes.count)
    let count = output.withUnsafeMutableBytes {
      archive_read_data(archive, $0.baseAddress, $0.count)
    }
    #expect(count == bytes.count)
    #expect(output == bytes)
    #expect(archive_read_next_header(archive, &entry) == ARCHIVE_EOF)
  }
  let decoder = try ZstdStream(encoding: false)
  var decoded = Data()
  for offset in stride(from: 0, to: encoded.count, by: 7) {
    let end = min(offset + 7, encoded.count)
    try decoder.process(encoded.subdata(in: offset..<end), final: end == encoded.count) {
      decoded.append($0)
    }
  }
  #expect(decoded == bytes)
  let file = temporary.url.appendingPathComponent("zstd")
  try SafeFile.writeNew(encoded, to: file)
  let input = try SafeFile.openRegular(file)
  defer { try? input.close() }
  let result = try OCICompression.process(
    input: input, bytes: UInt64(encoded.count), encoding: false,
    maximumOutput: UInt64(bytes.count), codec: .zstd, cancellation: nil
  ) { _ in }
  #expect(result.inputDigest == "sha256:" + SafeFile.sha256(encoded))
  #expect(result.outputDigest == "sha256:" + SafeFile.sha256(bytes))
  try input.seek(toOffset: 0)
  #expect(throws: MisoError.self) {
    try OCICompression.process(
      input: input, bytes: UInt64(encoded.count), encoding: false,
      maximumOutput: UInt64(bytes.count - 1), codec: .zstd, cancellation: nil
    ) { _ in }
  }
  for invalid in [Data(encoded.dropLast()), encoded + Data([0]), Data([1, 2, 3, 4, 5])] {
    let stream = try ZstdStream(encoding: false)
    #expect(throws: MisoError.self) {
      try stream.process(invalid, final: true) { _ in }
    }
  }
  #expect(throws: MisoError.self) {
    try decoder.process(Data([0]), final: true) { _ in }
  }
}

@Test func parallelOCIPackingPreservesOrderAndDeduplicatesIdenticalLayers() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let source = temporary.url.appendingPathComponent("source")
  let blobs = temporary.url.appendingPathComponent("blobs")
  try SafeFile.makeDirectory(source)
  try SafeFile.writeNew(
    Data(#"{"version":1,"os":"darwin","arch":"arm64"}"#.utf8),
    to: source.appendingPathComponent("config.json"))
  try SafeFile.writeNew(Data([1]), to: source.appendingPathComponent("nvram.bin"))
  let disk = try SafeFile.create(source.appendingPathComponent("disk.img"))
  defer { try? disk.close() }
  let prefix = OCIManifest.layerBytes * 2
  try disk.seek(toOffset: prefix)
  try disk.write(contentsOf: Data([1, 2, 3]))
  let manifest = try await OCIPack.run(
    source: source, blobs: blobs, labels: [:], cancellation: CancellationToken(), concurrency: 3)
  #expect(try manifest.validate() == prefix + 3)
  #expect(manifest.layers[1] == manifest.layers[2])
  #expect(manifest.layers[3].annotations?["org.cirruslabs.tart.uncompressed-size"] == "3")
  #expect(
    manifest.layers[3].annotations?["org.cirruslabs.tart.uncompressed-content-digest"]
      == "sha256:" + SafeFile.sha256(Data([1, 2, 3])))
  #expect(manifest.layers[1].mediaType == OCIDiskCompression.zstd.mediaType)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == manifest.blobs.count)
}

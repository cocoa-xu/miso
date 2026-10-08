import Compression
import CryptoKit
import Foundation

public enum OCIDiskCompression: String, CaseIterable, Sendable {
  case lz4
  case zstd

  var mediaType: String {
    switch self {
    case .lz4: OCIManifest.diskType
    case .zstd: "application/vnd.cirruslabs.tart.disk.v2+zstd"
    }
  }

  init?(mediaType: String) {
    guard let codec = Self.allCases.first(where: { $0.mediaType == mediaType }) else { return nil }
    self = codec
  }
}

enum OCICompression {
  struct Result {
    let inputDigest: String
    let outputDigest: String
    let outputBytes: UInt64
  }

  static func process(
    input: FileHandle, bytes: UInt64, encoding: Bool, maximumOutput: UInt64,
    codec: OCIDiskCompression = .lz4,
    cancellation: CancellationToken?, write: (Data) throws -> Void
  ) throws -> Result {
    if codec == .zstd {
      return try zstd(
        input: input, bytes: bytes, encoding: encoding, maximumOutput: maximumOutput,
        cancellation: cancellation, write: write)
    }
    let capacity = 1 << 20
    let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { output.deallocate() }
    var stream = compression_stream(
      dst_ptr: output, dst_size: 0, src_ptr: UnsafePointer(output), src_size: 0, state: nil)
    guard
      compression_stream_init(
        &stream, encoding ? COMPRESSION_STREAM_ENCODE : COMPRESSION_STREAM_DECODE,
        COMPRESSION_LZ4) == COMPRESSION_STATUS_OK
    else { throw MisoError.invalid("Cannot initialize OCI LZ4 stream") }
    defer { compression_stream_destroy(&stream) }
    var inputHash = SHA256()
    var outputHash = SHA256()
    var remaining = bytes
    var outputBytes: UInt64 = 0
    var ended = false
    while remaining > 0 {
      try cancellation?.check()
      let data = try input.readExactly(Int(min(remaining, UInt64(capacity))))
      remaining -= UInt64(data.count)
      inputHash.update(data: data)
      try data.withUnsafeBytes { buffer in
        stream.src_ptr = buffer.bindMemory(to: UInt8.self).baseAddress!
        stream.src_size = data.count
        repeat {
          try cancellation?.check()
          try Task.checkCancellation()
          stream.dst_ptr = output
          stream.dst_size = capacity
          let status = compression_stream_process(
            &stream, remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
          guard status != COMPRESSION_STATUS_ERROR else {
            throw MisoError.invalid("Invalid OCI LZ4 stream")
          }
          let count = capacity - stream.dst_size
          guard UInt64(count) <= maximumOutput - outputBytes else {
            throw MisoError.invalid("OCI layer exceeds its declared size")
          }
          if count > 0 {
            let chunk = Data(bytes: output, count: count)
            outputHash.update(data: chunk)
            try write(chunk)
            outputBytes += UInt64(count)
          }
          if status == COMPRESSION_STATUS_END {
            guard remaining == 0, stream.src_size == 0 else {
              throw MisoError.invalid("Trailing bytes in OCI LZ4 stream")
            }
            ended = true
            break
          }
          if stream.src_size == 0, stream.dst_size > 0 { break }
        } while true
      }
    }
    guard ended else { throw MisoError.invalid("Incomplete OCI LZ4 stream") }
    return Result(
      inputDigest: "sha256:" + SafeFile.hex(Data(inputHash.finalize())),
      outputDigest: "sha256:" + SafeFile.hex(Data(outputHash.finalize())),
      outputBytes: outputBytes)
  }

  private static func zstd(
    input: FileHandle, bytes: UInt64, encoding: Bool, maximumOutput: UInt64,
    cancellation: CancellationToken?, write: (Data) throws -> Void
  ) throws -> Result {
    let stream = try ZstdStream(encoding: encoding)
    var remaining = bytes
    var inputHash = SHA256()
    var outputHash = SHA256()
    var outputBytes: UInt64 = 0
    while remaining > 0 {
      try cancellation?.check()
      let data = try input.readExactly(Int(min(remaining, 1 << 20)))
      remaining -= UInt64(data.count)
      inputHash.update(data: data)
      try stream.process(data, final: remaining == 0) { chunk in
        try cancellation?.check()
        guard UInt64(chunk.count) <= maximumOutput - outputBytes else {
          throw MisoError.invalid("OCI layer exceeds its declared size")
        }
        outputHash.update(data: chunk)
        try write(chunk)
        outputBytes += UInt64(chunk.count)
      }
    }
    guard stream.ended else { throw MisoError.invalid("Incomplete OCI Zstd stream") }
    return Result(
      inputDigest: "sha256:" + SafeFile.hex(Data(inputHash.finalize())),
      outputDigest: "sha256:" + SafeFile.hex(Data(outputHash.finalize())),
      outputBytes: outputBytes)
  }
}

import ArchiveKit
import CZstd
import Foundation

final class ZstdStream {
  private let context: OpaquePointer
  private let encoding: Bool
  private let output: UnsafeMutablePointer<UInt8>
  private(set) var ended = false

  init(encoding: Bool) throws {
    self.encoding = encoding
    guard let context = encoding ? ZSTD_createCStream() : ZSTD_createDStream() else {
      throw MisoError.invalid("Cannot allocate Zstd stream")
    }
    do {
      try Self.check(encoding ? ZSTD_initCStream(context, 9) : ZSTD_initDStream(context))
      if encoding { try Self.check(ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1)) }
    } catch {
      if encoding { ZSTD_freeCStream(context) } else { ZSTD_freeDStream(context) }
      throw error
    }
    self.context = context
    output = .allocate(capacity: 1 << 20)
  }

  deinit {
    if encoding { ZSTD_freeCStream(context) } else { ZSTD_freeDStream(context) }
    output.deallocate()
  }

  func process(_ data: Data, final: Bool, write: (Data) throws -> Void) throws {
    guard !ended else { throw MisoError.invalid("Trailing bytes in OCI Zstd stream") }
    try data.withUnsafeBytes { bytes in
      var input = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
      while true {
        try Task.checkCancellation()
        var buffer = ZSTD_outBuffer(dst: output, size: 1 << 20, pos: 0)
        let result =
          encoding
          ? ZSTD_compressStream2(context, &buffer, &input, final ? ZSTD_e_end : ZSTD_e_continue)
          : ZSTD_decompressStream(context, &buffer, &input)
        try Self.check(result)
        if buffer.pos > 0 { try write(Data(bytes: output, count: buffer.pos)) }
        if result == 0, !encoding || final {
          guard input.pos == input.size else {
            throw MisoError.invalid("Trailing bytes in OCI Zstd stream")
          }
          ended = true
          break
        }
        if input.pos == input.size, buffer.pos < buffer.size, !encoding || !final { break }
      }
    }
    if final, !ended { throw MisoError.invalid("Incomplete OCI Zstd stream") }
  }

  private static func check(_ result: Int) throws {
    guard ZSTD_isError(result) == 0 else {
      throw MisoError.invalid("OCI Zstd stream: " + String(cString: ZSTD_getErrorName(result)))
    }
  }
}

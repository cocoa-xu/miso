import Compression
import CryptoKit
import Foundation

public enum KernelCollection {
  public struct Receipt: Codable, Sendable {
    public let profile: RestoreProfile
    public let preparedJournal: ImageBundle.FileRecord
    public let kernel: ImageBundle.FileRecord
    public let blobs: [String: ImageBundle.FileRecord]
  }

  public static func prepare(prepared: URL, output: URL, cancellation: CancellationToken? = nil)
    throws -> Receipt
  {
    let inputs = try PreparedInputs(prepared)
    let source = try inputs.component("KernelCache", cancellation: cancellation)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-policy-material", cancellation: cancellation)
    return try journal.perform {
      try journal.setMetadata("target", value: inputs.receipt.profile.release)
      try journal.setMetadata("preparedJournal", value: inputs.journalRecord)
      let encoded = try SafeFile.read(source, limit: 128 << 20)
      let fields = try Image4.payloadFields(encoded)
      guard fields[1].content == Data("krnl".utf8) else {
        throw MisoError.invalid("Expected kernelcache payload")
      }
      let kernel = journal.output.appendingPathComponent("kernel.macho")
      try decompress(fields[3].content, output: kernel, cancellation: journal.cancellation)
      let collection = try MachOImage(SafeFile.read(kernel, limit: 512 << 20))
      guard collection.type == 12 else { throw MisoError.invalid("Expected a kernel fileset") }
      let policy = try collection.member("com.apple.security.AppleVPBootPolicy")
      let payload = try policy.bytes("__policy_payload", count: 22)
      guard
        Data(SHA384.hash(data: payload)) == (try policy.bytes("__policy_payload_digest", count: 48))
      else {
        throw MisoError.invalid("Virtual policy payload digest mismatch")
      }
      var blobs: [String: ImageBundle.FileRecord] = [:]
      for (name, data) in [
        ("key", try policy.blob("_hacktivation_oik")),
        ("certificates", try policy.blob("_hacktivation_oic")), ("payload", payload),
      ] {
        let destination = journal.output.appendingPathComponent(name + ".der")
        try SafeFile.writeNew(data, to: destination)
        blobs[name] = try Artifacts.record(destination, relativeTo: journal.output)
      }
      return Receipt(
        profile: inputs.receipt.profile, preparedJournal: inputs.journalRecord,
        kernel: try Artifacts.record(kernel, relativeTo: journal.output), blobs: blobs)
    }
  }

  static func decompress(
    _ input: Data, output: URL, maximumBytes: Int = 512 << 20, cancellation: CancellationToken
  ) throws {
    guard
      ["bvx2", "bvx1", "bvxn", "bvx-"].contains(String(decoding: input.prefix(4), as: UTF8.self)),
      maximumBytes > 0, maximumBytes <= 512 << 20
    else { throw MisoError.unsupported("kernelcache compression") }
    let destination = try SafeFile.create(output)
    defer { try? destination.close() }
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    defer { buffer.deallocate() }
    var stream = compression_stream(
      dst_ptr: buffer, dst_size: 1 << 20, src_ptr: buffer, src_size: 0, state: nil)
    guard
      compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE)
        == COMPRESSION_STATUS_OK
    else {
      throw MisoError.invalid("Initialize kernel decompressor")
    }
    defer { compression_stream_destroy(&stream) }
    var total = 0
    try input.withUnsafeBytes { bytes in
      stream.src_ptr = bytes.bindMemory(to: UInt8.self).baseAddress!
      stream.src_size = bytes.count
      while true {
        try cancellation.check()
        stream.dst_ptr = buffer
        stream.dst_size = 1 << 20
        let before = stream.src_size
        let status = compression_stream_process(
          &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        let count = (1 << 20) - stream.dst_size
        guard status != COMPRESSION_STATUS_ERROR, count <= maximumBytes - total else {
          throw MisoError.invalid("Invalid or oversized compressed kernel")
        }
        if count > 0 { try destination.write(contentsOf: Data(bytes: buffer, count: count)) }
        total += count
        if status == COMPRESSION_STATUS_END {
          guard stream.src_size == 0, total > 0 else {
            throw MisoError.invalid("Kernel compressed stream has trailing data")
          }
          break
        }
        guard before != stream.src_size || count > 0 else {
          throw MisoError.invalid("Truncated compressed kernel")
        }
      }
    }
    try destination.synchronize()
  }
}

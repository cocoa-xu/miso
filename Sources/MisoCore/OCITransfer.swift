import Darwin
import Foundation

public enum OCITransfer {
  public struct Receipt: Codable, Sendable {
    public let reference: String
    public let bytes: UInt64
    public let transferredBytes: UInt64
    public let skippedBlobs: Int
    public let vmStarted: Bool
  }

  public static func push(
    source: URL, reference: String, output: URL, concurrency: Int = 4,
    compression: OCIDiskCompression = .zstd,
    labels: [String: String] = [:], username: String?, password: String?,
    cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Receipt {
    let reference = try OCIReference(reference)
    guard !reference.version.hasPrefix("sha256:"), (1...16).contains(concurrency) else {
      throw MisoError.invalid("Upload requires a tag and concurrency between 1 and 16")
    }
    try SafeFile.requireNoSymlinks(source)
    let journal = try ExecutionJournal(
      output: output, operation: "oci-push", cancellation: cancellation)
    let blobs = journal.output.appendingPathComponent("blobs")
    defer { try? FileManager.default.removeItem(at: blobs) }
    do {
      let registry = try OCIRegistry(
        reference: reference, username: username, password: password, pushing: true,
        cancellation: journal.cancellation, configuration: configuration)
      try await registry.retry(progress: nil, id: UUID()) {
        let probe = try await registry.request("GET", url: reference.url("tags/list?n=1"))
        try registry.require(probe.http, codes: [200, 404])
      }
      let manifest = try await OCIPack.run(
        source: source, blobs: blobs, labels: labels, cancellation: journal.cancellation,
        compression: compression, concurrency: concurrency)
      _ = try manifest.validate()
      let data = try JSON.encode(manifest)
      let digest = "sha256:" + SafeFile.sha256(data)
      try SafeFile.writeNew(data, to: journal.output.appendingPathComponent("manifest.json"))
      var missing: [OCIDescriptor] = []
      for blob in manifest.blobs {
        let exists = try await registry.retry(progress: nil, id: UUID()) {
          try await registry.contains(blob)
        }
        if !exists { missing.append(blob) }
      }
      let bytes = manifest.blobs.reduce(UInt64(data.count)) { $0 + $1.size }
      let transferred = missing.reduce(UInt64(data.count)) { $0 + $1.size }
      BuildProgress.write("Upload: \(manifest.blobs.count - missing.count) existing blobs skipped")
      let progress = TransferProgress("Upload", total: Int64(transferred))
      progress.start()
      defer { progress.stop() }
      try await parallel(missing, concurrency: concurrency) { blob in
        let id = UUID()
        try await registry.retry(progress: progress, id: id) {
          if try await registry.contains(blob) { return }
          let start = try await registry.request(
            "POST", url: reference.url("blobs/uploads/"), data: Data())
          try registry.require(start.http, codes: [202])
          var location = URLComponents(
            url: try registry.uploadLocation(start.http), resolvingAgainstBaseURL: false)!
          location.queryItems =
            (location.queryItems ?? []).filter { $0.name != "digest" }
            + [URLQueryItem(name: "digest", value: blob.digest)]
          let result = try await registry.request(
            "PUT", url: location.url!, file: blob.file(in: blobs),
            contentType: "application/octet-stream", progress: progress, id: id)
          try registry.require(result.http, codes: [201])
          try registry.checkDigest(result.http, expected: blob.digest)
        }
        progress.complete(id, bytes: Int64(blob.size))
        try FileManager.default.removeItem(at: blob.file(in: blobs))
      }
      let id = UUID()
      try await registry.retry(progress: progress, id: id) {
        let result = try await registry.request(
          "PUT", url: reference.url("manifests/\(reference.version)"), data: data,
          contentType: OCIManifest.manifestType, progress: progress, id: id)
        try registry.require(result.http, codes: [201])
        try registry.checkDigest(result.http, expected: digest)
      }
      progress.complete(id, bytes: Int64(data.count))
      let receipt = Receipt(
        reference: reference.name + "@" + digest, bytes: bytes,
        transferredBytes: progress.transferredBytes,
        skippedBlobs: manifest.blobs.count - missing.count, vmStarted: false)
      try SafeFile.writeNew(
        JSON.encode(receipt), to: journal.output.appendingPathComponent("transfer.json"))
      try journal.finish(receipt)
      return receipt
    } catch {
      try? journal.fail(error)
      throw error
    }
  }

  public static func pull(
    reference: String, output: URL, concurrency: Int = 4,
    username: String? = nil, password: String? = nil, cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Receipt {
    let reference = try OCIReference(reference)
    guard (1...16).contains(concurrency) else {
      throw MisoError.invalid("Concurrency must be between 1 and 16")
    }
    let journal = try ExecutionJournal(
      output: output, operation: "oci-pull", cancellation: cancellation)
    let staging = journal.output.appendingPathComponent("staging")
    defer { try? FileManager.default.removeItem(at: staging) }
    do {
      let registry = try OCIRegistry(
        reference: reference, username: username, password: password, pushing: false,
        cancellation: journal.cancellation, configuration: configuration)
      let response = try await registry.retry(progress: nil, id: UUID()) {
        let response = try await registry.request(
          "GET", url: reference.url("manifests/\(reference.version)"))
        try registry.require(response.http, codes: [200])
        return response
      }
      let digest = "sha256:" + SafeFile.sha256(response.data)
      try registry.checkDigest(response.http, expected: digest)
      guard !reference.version.hasPrefix("sha256:") || reference.version == digest else {
        throw MisoError.invalid("OCI manifest differs from the requested digest")
      }
      let manifest = try JSONDecoder().decode(OCIManifest.self, from: response.data)
      let diskSize = try manifest.validate()
      try SafeFile.writeNew(
        response.data, to: journal.output.appendingPathComponent("manifest.json"))
      try SafeFile.makeDirectory(staging)
      let blobs = staging.appendingPathComponent("blobs")
      let vm = staging.appendingPathComponent("vm")
      try SafeFile.makeDirectory(blobs)
      try SafeFile.makeDirectory(vm)
      let diskURL = vm.appendingPathComponent("disk.img")
      let disk = try SafeFile.create(diskURL)
      try disk.truncate(atOffset: diskSize)
      try disk.close()
      var positions: [String: [UInt64]] = [:]
      var offset: UInt64 = 0
      for layer in manifest.layers.dropFirst().dropLast() {
        positions[layer.digest, default: []].append(offset)
        offset += UInt64(layer.annotations!["org.cirruslabs.tart.uncompressed-size"]!)!
      }
      let offsets = positions
      let token = journal.cancellation
      let bytes = manifest.blobs.reduce(UInt64(0)) { $0 + $1.size }
      let progress = TransferProgress("Download", total: Int64(bytes))
      progress.start()
      defer { progress.stop() }
      try await parallel(manifest.blobs, concurrency: concurrency) { blob in
        let id = UUID()
        let file = blob.file(in: blobs)
        try Artifacts.requireSpace(blob.size, at: blobs)
        try await registry.retry(progress: progress, id: id) {
          try await registry.download(blob, to: file, progress: progress, id: id)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try unpack(blob, file: file, vm: vm, offsets: offsets[blob.digest], cancellation: token)
        progress.complete(id, bytes: Int64(blob.size))
      }
      try journal.cancellation.check()
      let receipt = Receipt(
        reference: reference.name + "@" + digest, bytes: bytes,
        transferredBytes: progress.transferredBytes,
        skippedBlobs: 0, vmStarted: false)
      try FileManager.default.moveItem(at: vm, to: journal.output.appendingPathComponent("vm"))
      try SafeFile.writeNew(
        JSON.encode(receipt), to: journal.output.appendingPathComponent("transfer.json"))
      try journal.finish(receipt)
      return receipt
    } catch {
      try? journal.fail(error)
      throw error
    }
  }

  static func unpack(
    _ blob: OCIDescriptor, file: URL, vm: URL, offsets: [UInt64]?, cancellation: CancellationToken
  ) throws {
    try cancellation.check()
    if let codec = OCIDiskCompression(mediaType: blob.mediaType) {
      guard let offsets, !offsets.isEmpty,
        let count = blob.annotations?["org.cirruslabs.tart.uncompressed-size"].flatMap(UInt64.init)
      else { throw MisoError.invalid("Missing OCI disk offsets") }
      let input = try SafeFile.openRegular(file)
      defer { try? input.close() }
      let disk = try SafeFile.openRegular(vm.appendingPathComponent("disk.img"), writable: true)
      defer { try? disk.close() }
      var position: UInt64 = 0
      let zeroes = Data(repeating: 0, count: 1 << 20)
      var holes: [APFSCompaction.Extent] = []
      let result = try OCICompression.process(
        input: input, bytes: blob.size, encoding: false, maximumOutput: count, codec: codec,
        cancellation: cancellation
      ) { data in
        if data != zeroes.prefix(data.count) {
          for offset in offsets {
            try disk.seek(toOffset: offset + position)
            try disk.write(contentsOf: data)
          }
        } else if let last = holes.indices.last, holes[last].end == position {
          holes[last].length += UInt64(data.count)
        } else {
          holes.append(APFSCompaction.Extent(offset: position, length: UInt64(data.count)))
        }
        position += UInt64(data.count)
      }
      guard result.inputDigest == blob.digest, result.outputBytes == count,
        result.outputDigest == blob.annotations?["org.cirruslabs.tart.uncompressed-content-digest"]
      else { throw MisoError.invalid("OCI disk layer digest or size mismatch") }
      try disk.synchronize()
      for offset in offsets {
        for hole in holes {
          let start = ((offset + hole.offset + 4095) / 4096) * 4096
          let end = ((offset + hole.end) / 4096) * 4096
          if start < end {
            var range = fpunchhole_t(
              fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
            guard fcntl(disk.fileDescriptor, F_PUNCHHOLE, &range) == 0 else {
              throw MisoError.system("Punch zero-filled OCI disk blocks", errno)
            }
          }
        }
      }
      try disk.synchronize()
    } else {
      let data = try SafeFile.read(file, limit: Int(blob.size))
      guard UInt64(data.count) == blob.size, "sha256:" + SafeFile.sha256(data) == blob.digest else {
        throw MisoError.invalid("OCI metadata digest mismatch")
      }
      switch blob.mediaType {
      case OCIManifest.configType:
        try OCIPack.validateConfiguration(data)
        try SafeFile.writeNew(data, to: vm.appendingPathComponent("config.json"))
      case OCIManifest.nvramType:
        try SafeFile.writeNew(data, to: vm.appendingPathComponent("nvram.bin"))
      case OCIManifest.imageConfigType:
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["architecture"] as? String == "arm64", value["os"] as? String == "darwin"
        else { throw MisoError.invalid("Unsupported OCI image configuration") }
        let config = value["config"] as? [String: Any]
        let labels = config?["Labels"] as? [String: String]
        guard (labels?["org.cirruslabs.tart.disk.format"] ?? "raw") == "raw" else {
          throw MisoError.invalid("Unsupported OCI disk format")
        }
      default: throw MisoError.invalid("Unsupported OCI blob")
      }
    }
  }

  private static func parallel<T: Sendable>(
    _ values: [T], concurrency: Int, body: @escaping @Sendable (T) async throws -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      var iterator = values.makeIterator()
      for _ in 0..<concurrency {
        if let value = iterator.next() { group.addTask { try await body(value) } }
      }
      while try await group.next() != nil {
        if let value = iterator.next() { group.addTask { try await body(value) } }
      }
    }
  }
}

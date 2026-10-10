import Foundation
import Testing

@testable import MisoCore

private final class RegistryFixture: @unchecked Sendable {
  let lock = NSLock()
  var blobs: [String: Data] = [:]
  var manifest: Data?
  var failUpload = true
  var expireToken = true
  var tokenRequests = 0
  var uploads = 0
  var corruptDownload = false
  var rejectUpload = false
  var stall = false
  var stallDownload = false
  var downloadFailures = 0
  var downloadRanges: [String] = []
  var ignoreRanges = false
  var invalidRange = false
  var expireResumedDownload = false

  func respond(_ request: URLRequest) throws -> (Int, [String: String], Data) {
    try lock.withLock {
      let url = request.url!
      let method = request.httpMethod!
      var headers: [String: String] = [:]
      let empty = Data()
      if url.path == "/token" {
        tokenRequests += 1
        return (200, headers, Data("{\"token\":\"fixture-token\"}".utf8))
      }
      guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" else {
        return (403, headers, empty)
      }
      if url.path.hasSuffix("tags/list") { return (200, headers, Data("{}".utf8)) }
      if url.path.contains("/manifests/") {
        if method == "PUT" {
          let data = try body(request)
          let decoded = try JSONDecoder().decode(OCIManifest.self, from: data)
          guard decoded.blobs.allSatisfy({ blobs[$0.digest] != nil }) else {
            return (400, headers, empty)
          }
          manifest = data
          headers["Docker-Content-Digest"] = "sha256:" + SafeFile.sha256(data)
          return (201, headers, empty)
        }
        return (manifest == nil ? 404 : 200, headers, manifest ?? empty)
      }
      if method == "POST" {
        headers["Location"] = "https://ghcr.io:443/v2/uploads/opaque?state=opaque"
        return (202, headers, empty)
      }
      if method == "PUT" {
        if rejectUpload { return (403, headers, empty) }
        if failUpload {
          failUpload = false
          headers["Retry-After"] = "1"
          return (503, headers, empty)
        }
        let data = try body(request)
        let digest = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
          .first(where: { $0.name == "digest" })!.value!
        guard digest == "sha256:" + SafeFile.sha256(data) else { return (400, headers, empty) }
        blobs[digest] = data
        uploads += 1
        headers["Docker-Content-Digest"] = digest
        return (201, headers, empty)
      }
      if method == "HEAD", expireToken {
        expireToken = false
        return (401, headers, empty)
      }
      guard let data = blobs[url.lastPathComponent] else { return (404, headers, empty) }
      headers["Content-Length"] = String(data.count)
      headers["Docker-Content-Digest"] = url.lastPathComponent
      if method == "HEAD" { return (200, headers, empty) }
      let range = request.value(forHTTPHeaderField: "Range")
      downloadRanges.append(range ?? "none")
      if range != nil, expireResumedDownload {
        expireResumedDownload = false
        return (401, [:], empty)
      }
      if let range, !ignoreRanges {
        let offset = Int(range.dropFirst(6).dropLast())!
        headers["Content-Range"] =
          invalidRange
          ? "bytes 0-\(data.count - 1)/\(data.count)"
          : "bytes \(offset)-\(data.count - 1)/\(data.count)"
        headers["Content-Length"] = String(data.count - offset)
        return (206, headers, Data(data.dropFirst(offset)))
      }
      return (200, headers, corruptDownload ? Data(repeating: 1, count: data.count) : data)
    }
  }

  private func body(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 << 10)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { throw stream.streamError! }
      if count == 0 { return data }
      data.append(contentsOf: buffer.prefix(count))
    }
  }
}

private final class RegistryProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  nonisolated(unsafe) static var fixture = RegistryFixture()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    do {
      let fixture = Self.lock.withLock { Self.fixture }
      if fixture.lock.withLock({ fixture.stall }) { return }
      let (status, headers, data) = try fixture.respond(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      let disconnect = fixture.lock.withLock {
        guard fixture.downloadFailures > 0, [200, 206].contains(status),
          request.url!.path.contains("/blobs/")
        else {
          return false
        }
        fixture.downloadFailures -= 1
        return true
      }
      if disconnect {
        client?.urlProtocol(self, didLoad: data.prefix(64 << 10))
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
          guard let self else { return }
          self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
        return
      }
      if fixture.lock.withLock({ fixture.stallDownload }), request.url!.path.contains("/blobs/") {
        client?.urlProtocol(self, didLoad: data.prefix(64 << 10))
        return
      }
      if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}

@Suite(.serialized) struct OCITransferTests {
  @Test(arguments: [false, true])
  func interruptedDownloadsResumeWithoutRepeatingBytes(expireToken: Bool) async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (fixture, configuration) = setup()
    let bytes = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
    let blob = OCIDescriptor(
      mediaType: OCIManifest.nvramType, size: UInt64(bytes.count),
      digest: "sha256:" + SafeFile.sha256(bytes))
    fixture.blobs[blob.digest] = bytes
    fixture.downloadFailures = 2
    fixture.expireResumedDownload = expireToken
    let registry = try OCIRegistry(
      reference: OCIReference("ghcr.io/fixture/image:test"), username: nil, password: nil,
      pushing: false, cancellation: CancellationToken(), configuration: configuration)
    let progress = TransferProgress("Test", total: Int64(blob.size))
    let destination = temporary.url.appendingPathComponent("blob")
    let id = UUID()
    try await registry.retry(progress: nil, id: id, sleep: { _ in }) {
      try await registry.download(blob, to: destination, progress: progress, id: id)
    }
    #expect(try SafeFile.read(destination, limit: bytes.count) == bytes)
    #expect(progress.transferredBytes == blob.size)
    #expect(
      fixture.downloadRanges
        == (expireToken
          ? ["none", "bytes=65536-", "bytes=65536-", "bytes=131072-"]
          : ["none", "bytes=65536-", "bytes=131072-"]))
    #expect(
      !FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
  }

  @Test(arguments: [false, true])
  func resumedDownloadHandlesIgnoredOrInvalidRanges(invalid: Bool) async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (fixture, configuration) = setup()
    let bytes = Data(repeating: 3, count: 1 << 20)
    let blob = OCIDescriptor(
      mediaType: OCIManifest.nvramType, size: UInt64(bytes.count),
      digest: "sha256:" + SafeFile.sha256(bytes))
    fixture.blobs[blob.digest] = bytes
    fixture.downloadFailures = 1
    fixture.ignoreRanges = !invalid
    fixture.invalidRange = invalid
    let registry = try OCIRegistry(
      reference: OCIReference("ghcr.io/fixture/image:test"), username: nil, password: nil,
      pushing: false, cancellation: CancellationToken(), configuration: configuration)
    let progress = TransferProgress("Test", total: Int64(blob.size))
    let destination = temporary.url.appendingPathComponent("blob")
    let id = UUID()
    do {
      try await registry.retry(progress: nil, id: id, sleep: { _ in }) {
        try await registry.download(blob, to: destination, progress: progress, id: id)
      }
      #expect(!invalid)
      #expect(try SafeFile.read(destination, limit: bytes.count) == bytes)
      #expect(progress.transferredBytes == blob.size + (64 << 10))
    } catch is MisoError {
      #expect(invalid)
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    #expect(fixture.downloadRanges == ["none", "bytes=65536-"])
    #expect(
      !FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
  }

  @Test func downloadReportsBytesBeforeTheLayerCompletes() async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (fixture, configuration) = setup()
    let bytes = Data(repeating: 1, count: 1 << 20)
    let blob = OCIDescriptor(
      mediaType: OCIManifest.nvramType, size: UInt64(bytes.count),
      digest: "sha256:" + SafeFile.sha256(bytes))
    fixture.blobs[blob.digest] = bytes
    fixture.stallDownload = true
    let token = try CancellationToken()
    let registry = try OCIRegistry(
      reference: OCIReference("ghcr.io/fixture/image:test"), username: nil, password: nil,
      pushing: false, cancellation: token, configuration: configuration)
    let progress = TransferProgress("Test", total: Int64(blob.size))
    let destination = temporary.url.appendingPathComponent("blob")
    let download = Task {
      try await registry.download(blob, to: destination, progress: progress, id: UUID())
    }
    for _ in 0..<100 {
      if progress.transferredBytes > 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    token.cancel()
    await #expect(throws: CancellationError.self) { try await download.value }
    #expect(progress.transferredBytes == 64 << 10)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func credentialsStayOnGHCRAndInvalidReferencesAreRejected() async throws {
    for reference in [
      "https://ghcr.io/a/b:t", "ghcr.io/a/../b:t", "ghcr.io/a/b", "ghcr.io/a/b:t?token=secret",
    ] {
      #expect(throws: MisoError.self) { try OCIReference(reference) }
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let origin = URL(string: "https://ghcr.io/v2/fixture/image/blobs/sha256:test")!
    var original = URLRequest(url: origin)
    original.setValue("bytes=65536-", forHTTPHeaderField: "Range")
    let task = session.dataTask(with: original)
    let response = HTTPURLResponse(
      url: origin, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil)!
    let observer = OCIRegistry.Observer(
      blobRedirects: true, progress: nil, id: UUID())
    for destination in [
      "https://pkg-containers.githubusercontent.com/blob", "https://example.com/blob",
      "http://ghcr.io/blob",
    ] {
      var request = URLRequest(url: URL(string: destination)!)
      request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
      let redirected = await withCheckedContinuation { continuation in
        observer.urlSession(
          session, task: task, willPerformHTTPRedirection: response, newRequest: request
        ) {
          continuation.resume(returning: $0)
        }
      }
      if destination.contains("pkg-containers") {
        #expect(redirected != nil)
        #expect(redirected?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirected?.value(forHTTPHeaderField: "Range") == "bytes=65536-")
      } else {
        #expect(redirected == nil)
      }
    }
  }

  @Test func cancellationInterruptsAStalledRegistryRequest() async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (fixture, configuration) = setup()
    fixture.stall = true
    let token = try CancellationToken()
    let cancel = Task {
      try await Task.sleep(for: .milliseconds(50))
      token.cancel()
    }
    defer { cancel.cancel() }
    let output = temporary.url.appendingPathComponent("cancelled")
    await #expect(throws: CancellationError.self) {
      try await OCITransfer.pull(
        reference: "ghcr.io/fixture/image:test", output: output,
        cancellation: token, configuration: configuration)
    }
    let record = try JSON.read(
      ExecutionJournal.Record.self, from: output.appendingPathComponent("journal.json"))
    #expect(record.status == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("vm").path))
  }

  private func setup() -> (RegistryFixture, URLSessionConfiguration) {
    let fixture = RegistryFixture()
    RegistryProtocol.lock.withLock { RegistryProtocol.fixture = fixture }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RegistryProtocol.self]
    return (fixture, configuration)
  }

  private func source(_ temporary: TemporaryDirectory) throws -> (URL, Data) {
    let source = temporary.url.appendingPathComponent("source")
    try SafeFile.makeDirectory(source)
    try SafeFile.writeNew(
      Data("{\"version\":1,\"os\":\"darwin\",\"arch\":\"arm64\"}".utf8),
      to: source.appendingPathComponent("config.json"))
    try SafeFile.writeNew(Data([1, 2, 3, 4]), to: source.appendingPathComponent("nvram.bin"))
    let bytes = Data(repeating: 0, count: 2 << 20) + Data((0..<8192).map { UInt8($0 % 251) })
    try SafeFile.writeNew(bytes, to: source.appendingPathComponent("disk.img"))
    return (source, bytes)
  }

  @Test(arguments: OCIDiskCompression.allCases)
  func uploadRetriesRefreshesAuthenticationAndDownloadPreservesSparseData(
    compression: OCIDiskCompression
  ) async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (fixture, configuration) = setup()
    let (source, bytes) = try source(temporary)
    let receipt = try await OCITransfer.push(
      source: source, reference: "ghcr.io/fixture/image:test",
      output: temporary.url.appendingPathComponent("push"),
      concurrency: 3, compression: compression,
      username: "fixture", password: "secret", configuration: configuration)
    #expect(fixture.lock.withLock { fixture.tokenRequests } >= 2)
    #expect(
      !FileManager.default.fileExists(
        atPath: temporary.url.appendingPathComponent("push/blobs").path))
    let firstUploads = fixture.lock.withLock { fixture.uploads }
    let repeated = try await OCITransfer.push(
      source: source, reference: "ghcr.io/fixture/image:test",
      output: temporary.url.appendingPathComponent("push-again"),
      compression: compression,
      username: "fixture", password: "secret", configuration: configuration)
    #expect(repeated.skippedBlobs == firstUploads)
    #expect(fixture.lock.withLock { fixture.uploads } == firstUploads)
    fixture.lock.withLock { fixture.downloadFailures = 2 }
    let output = temporary.url.appendingPathComponent("pull")
    let downloaded = try await OCITransfer.pull(
      reference: repeated.reference, output: output, configuration: configuration)
    #expect(downloaded.reference == repeated.reference)
    #expect(
      try SafeFile.read(output.appendingPathComponent("vm/disk.img"), limit: 4 << 20) == bytes)
    let info = try FileMetadata.inspect(output.appendingPathComponent("vm/disk.img"))
    #expect(info.st_blocks * 512 < info.st_size / 2)
    #expect(receipt.vmStarted == false)
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("staging").path))
    fixture.lock.withLock { fixture.corruptDownload = true }
    let corrupt = temporary.url.appendingPathComponent("corrupt")
    await #expect(throws: (any Error).self) {
      try await OCITransfer.pull(
        reference: repeated.reference, output: corrupt, configuration: configuration)
    }
    #expect(!FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("vm").path))
    #expect(!FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("staging").path))
  }

  @Test func uploadFailureNeverPublishesManifestOrRemovesSource() async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (fixture, configuration) = setup()
    fixture.rejectUpload = true
    let (source, bytes) = try source(temporary)
    let output = temporary.url.appendingPathComponent("failed")
    await #expect(throws: OCIRegistryError.self) {
      try await OCITransfer.push(
        source: source, reference: "ghcr.io/fixture/image:test", output: output,
        username: "fixture", password: "secret", configuration: configuration)
    }
    #expect(fixture.lock.withLock { fixture.manifest } == nil)
    #expect(try SafeFile.read(source.appendingPathComponent("disk.img"), limit: 4 << 20) == bytes)
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("blobs").path))
    let record = try JSON.read(
      ExecutionJournal.Record.self, from: output.appendingPathComponent("journal.json"))
    #expect(record.status == .failed)
  }

  @Test func repeatedDiskLayersWriteEveryOffsetAndRejectConflictingMetadata() async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (source, bytes) = try source(temporary)
    let blobs = temporary.url.appendingPathComponent("blobs")
    let manifest = try await OCIPack.run(
      source: source, blobs: blobs, labels: [:], cancellation: CancellationToken())
    let layer = manifest.layers[1]
    let output = temporary.url.appendingPathComponent("vm")
    try SafeFile.makeDirectory(output)
    let disk = try SafeFile.create(output.appendingPathComponent("disk.img"))
    try disk.truncate(atOffset: UInt64(bytes.count * 2))
    try disk.close()
    try OCITransfer.unpack(
      layer, file: layer.file(in: blobs), vm: output, offsets: [0, UInt64(bytes.count)],
      cancellation: CancellationToken())
    #expect(
      try SafeFile.read(output.appendingPathComponent("disk.img"), limit: 8 << 20) == bytes + bytes)
    var changed = layer
    changed.annotations?["org.cirruslabs.tart.uncompressed-size"] = "1"
    let invalid = OCIManifest(
      schemaVersion: 2, mediaType: manifest.mediaType, config: manifest.config,
      layers: [manifest.layers[0], layer, changed, manifest.layers.last!],
      annotations: manifest.annotations)
    #expect(throws: MisoError.self) { try invalid.validate() }
  }
}

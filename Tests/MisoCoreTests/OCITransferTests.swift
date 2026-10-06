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
        headers["Location"] = "/v2/fixture/image/blobs/uploads/upload?state=opaque"
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
      let (status, headers, data) = try fixture.respond(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
}

@Suite(.serialized) struct OCITransferTests {
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

  @Test func uploadRetriesRefreshesAuthenticationAndDownloadPreservesSparseData() async throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (fixture, configuration) = setup()
    let (source, bytes) = try source(temporary)
    let receipt = try await OCITransfer.push(
      source: source, reference: "ghcr.io/fixture/image:test",
      output: temporary.url.appendingPathComponent("push"),
      concurrency: 3, username: "fixture", password: "secret", configuration: configuration)
    #expect(fixture.lock.withLock { fixture.tokenRequests } >= 2)
    #expect(
      !FileManager.default.fileExists(
        atPath: temporary.url.appendingPathComponent("push/blobs").path))
    let firstUploads = fixture.lock.withLock { fixture.uploads }
    let repeated = try await OCITransfer.push(
      source: source, reference: "ghcr.io/fixture/image:test",
      output: temporary.url.appendingPathComponent("push-again"),
      username: "fixture", password: "secret", configuration: configuration)
    #expect(repeated.skippedBlobs == firstUploads)
    #expect(fixture.lock.withLock { fixture.uploads } == firstUploads)
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

  @Test func repeatedDiskLayersWriteEveryOffsetAndRejectConflictingMetadata() throws {
    let temporary = try TemporaryDirectory()
    defer { temporary.remove() }
    let (source, bytes) = try source(temporary)
    let blobs = temporary.url.appendingPathComponent("blobs")
    let manifest = try OCIPack.run(
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

import Foundation
import Testing

@testable import MisoCore

private final class StubHTTPProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let url = request.url!
    let path = url.lastPathComponent
    if path == "protocol" || url.host == "ghcr.io" {
      let value =
        path == "protocol"
        ? request.value(forHTTPHeaderField: "Git-Protocol")
        : request.value(forHTTPHeaderField: "Authorization")
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data((value ?? "missing").utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if path == "post" {
      var body = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 128)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          body.append(contentsOf: buffer.prefix(count))
        }
      }
      let metadata =
        "\(request.httpMethod ?? "") \(request.value(forHTTPHeaderField: "Content-Type") ?? "")\n"
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(metadata.utf8) + body)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if path == "accept" {
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(
        self, didLoad: Data((request.value(forHTTPHeaderField: "Accept") ?? "missing").utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    if path == "stall" { return }
    if path == "redirect" {
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": "https://other.test/ok"])!
      client?.urlProtocol(
        self, wasRedirectedTo: URLRequest(url: URL(string: "https://other.test/ok")!),
        redirectResponse: response)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    let header = path == "declared-large" ? ["Content-Length": "1024"] : [:]
    let response = HTTPURLResponse(
      url: url, statusCode: path == "error" ? 500 : 200, httpVersion: "HTTP/1.1",
      headerFields: header)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if path != "empty" {
      client?.urlProtocol(
        self, didLoad: Data(repeating: 42, count: path == "streamed-large" ? 65 : 64))
    }
    client?.urlProtocolDidFinishLoading(self)
  }
}

@Test func nativeHTTPDeliversTheRegistryAcceptHeader() async throws {
  let accept = "application/vnd.npm.install-v1+json"
  let data = try await HTTPData.get(
    URL(string: "https://fixture.test/accept")!, maximumBytes: 64,
    accept: accept, configuration: stubConfiguration())
  #expect(String(data: data, encoding: .utf8) == accept)
}

@Test func nativeGitProtocolHeaderIsExplicit() async throws {
  let url = URL(string: "https://fixture.test/protocol")!
  #expect(
    try await HTTPData.get(url, maximumBytes: 64, configuration: stubConfiguration())
      == Data("missing".utf8))
  #expect(
    try await HTTPData.get(
      url, maximumBytes: 64, gitProtocolV2: true, configuration: stubConfiguration())
      == Data("version=2".utf8))
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let path = temporary.url.appendingPathComponent("post")
  try await HTTPFile.post(
    url, body: Data([1]), contentType: "application/x-git-upload-pack-request",
    to: path, maximumBytes: 64, gitProtocolV2: true, configuration: stubConfiguration())
  #expect(try SafeFile.read(path, limit: 64) == Data("version=2".utf8))
}

@Test func portableRubyUsesOnlyAnonymousRegistryAuthorization() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let path = temporary.url.appendingPathComponent("ruby")
  try await HTTPFile.homebrewBlob(
    String(repeating: "a", count: 64), to: path, configuration: stubConfiguration())
  #expect(try SafeFile.read(path, limit: 64) == Data("Bearer QQ==".utf8))
  await #expect(throws: MisoError.self) {
    try await HTTPFile.homebrewBlob("../other", to: path, configuration: stubConfiguration())
  }
}

@Test func boundedNativePayloadDownload() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("payload")
  try await HTTPFile.get(
    URL(string: "https://fixture.test/ok")!, to: output, maximumBytes: 64,
    configuration: stubConfiguration())
  #expect(try SafeFile.read(output, limit: 64) == Data(repeating: 42, count: 64))
}

@Test func nativePayloadPostPreservesBodyAndContentType() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("payload")
  let body = Data([0, 1, 2, 255])
  try await HTTPFile.post(
    URL(string: "https://fixture.test/post")!, body: body,
    contentType: "application/x-git-upload-pack-request", to: output, maximumBytes: 128,
    configuration: stubConfiguration())
  #expect(
    try SafeFile.read(output, limit: 128)
      == Data("POST application/x-git-upload-pack-request\n".utf8) + body)
}

@Test(arguments: ["declared-large", "streamed-large", "error", "empty", "redirect"])
func nativePayloadPostRejectsInvalidResponses(_ path: String) async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("payload")
  await #expect(throws: (any Error).self) {
    try await HTTPFile.post(
      URL(string: "https://fixture.test/\(path)")!, body: Data([1]),
      contentType: "application/x-git-upload-pack-request", to: output, maximumBytes: 64,
      configuration: stubConfiguration())
  }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func nativePayloadPostRejectsInvalidRequests() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  for (body, type) in [
    (Data(), "application/json"), (Data(repeating: 1, count: (4 << 20) + 1), "application/json"),
    (Data([1]), "text/plain"), (Data([1]), "application/json\r\nAuthorization: secret"),
  ] {
    await #expect(throws: MisoError.self) {
      try await HTTPFile.post(
        URL(string: "https://fixture.test/post")!, body: body, contentType: type,
        to: temporary.url.appendingPathComponent("payload"), maximumBytes: 128,
        configuration: stubConfiguration())
    }
  }
}

@Test func nativePayloadPostCancellation() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let token = try CancellationToken()
  let cancellation = Task {
    try await Task.sleep(for: .milliseconds(150))
    token.cancel()
  }
  defer { cancellation.cancel() }
  await #expect(throws: (any Error).self) {
    try await HTTPFile.post(
      URL(string: "https://fixture.test/stall")!, body: Data([1]),
      contentType: "application/x-git-upload-pack-request",
      to: temporary.url.appendingPathComponent("payload"), maximumBytes: 64,
      cancellation: token, configuration: stubConfiguration())
  }
}

@Test(arguments: ["declared-large", "streamed-large", "error", "empty", "redirect"])
func nativePayloadDownloadRejectsInvalidResponses(_ path: String) async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("payload")
  await #expect(throws: (any Error).self) {
    try await HTTPFile.get(
      URL(string: "https://fixture.test/\(path)")!, to: output, maximumBytes: 64,
      configuration: stubConfiguration())
  }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func nativePayloadDownloadCancellationWhileWaiting() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let token = try CancellationToken()
  let cancellation = Task {
    try await Task.sleep(for: .milliseconds(150))
    token.cancel()
  }
  defer { cancellation.cancel() }
  await #expect(throws: (any Error).self) {
    try await HTTPFile.get(
      URL(string: "https://fixture.test/stall")!,
      to: temporary.url.appendingPathComponent("payload"), maximumBytes: 64,
      cancellation: token, configuration: stubConfiguration())
  }
}

private func stubConfiguration() -> URLSessionConfiguration {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubHTTPProtocol.self]
  return configuration
}

@Test func nativeHTTPAcceptRejectsHeaderInjection() async {
  for accept in [
    "", "application/json\r\nAuthorization: secret", String(repeating: "a", count: 129),
  ] {
    await #expect(throws: (any Error).self) {
      try await HTTPData.get(
        URL(string: "https://fixture.test/ok")!, maximumBytes: 64,
        accept: accept, configuration: stubConfiguration())
    }
  }
}

@Test func appleKeyRedirectBoundaries() {
  let source = URL(string: "https://wkms-public.apple.com/fcs-keys/key=")!
  let target = URL(string: "https://fcs-keys-pub-prod.cdn-apple.com/fcs-keys/key=")!
  let gate = HTTPData.RedirectGate(source: source, policy: .appleKeys)
  for _ in 0..<3 { #expect(gate.accept(target)) }
  #expect(!gate.accept(target))
  #expect(!HTTPData.RedirectGate(source: source, policy: .reject).accept(target))
  for value in [
    "http://fcs-keys-pub-prod.cdn-apple.com/fcs-keys/key=",
    "https://fcs-keys-pub-prod.cdn-apple.com.evil.test/fcs-keys/key=",
    "https://unrelated.apple.com/fcs-keys/key=",
    "https://fcs-keys-pub-prod.cdn-apple.com/fcs-keys/different",
    "https://fcs-keys-pub-prod.cdn-apple.com:444/fcs-keys/key=",
    "https://user@fcs-keys-pub-prod.cdn-apple.com/fcs-keys/key=",
    "https://fcs-keys-pub-prod.cdn-apple.com/fcs-keys/key=?query",
  ] {
    #expect(!HTTPData.RedirectPolicy.appleKeys.permits(from: source, to: URL(string: value)!))
  }
}

@Test func homebrewBlobRedirectPreservesDigestIdentity() {
  let hash = String(repeating: "a", count: 64)
  let source = URL(string: "https://ghcr.io/v2/homebrew/core/portable-ruby/blobs/sha256:\(hash)")!
  let path = "/ghcrblobs19/blobs/sha256:" + hash
  let valid = URL(
    string: "https://pkg-containers.githubusercontent.com" + path + "?signature=fixture")!
  #expect(HTTPData.RedirectPolicy.homebrewBlob.permits(from: source, to: valid))
  for value in [
    "http://pkg-containers.githubusercontent.com" + path,
    "https://pkg-containers.githubusercontent.com.evil.test" + path,
    "https://pkg-containers.githubusercontent.com/ghcrblobs19/blobs/sha256:"
      + String(repeating: "b", count: 64),
    "https://user@pkg-containers.githubusercontent.com" + path,
    "https://pkg-containers.githubusercontent.com:444" + path,
    "https://pkg-containers.githubusercontent.com/other/" + hash,
  ] {
    #expect(!HTTPData.RedirectPolicy.homebrewBlob.permits(from: source, to: URL(string: value)!))
  }
}

@Test func boundedNativeHTTP() async throws {
  let result = try await HTTPData.get(
    URL(string: "https://fixture.test/ok")!, maximumBytes: 64, configuration: stubConfiguration())
  #expect(result == Data(repeating: 42, count: 64))
}

@Test(arguments: ["declared-large", "streamed-large", "error", "empty", "redirect"])
func nativeHTTPRejectsInvalidResponses(_ path: String) async {
  await #expect(throws: MisoError.self) {
    try await HTTPData.get(
      URL(string: "https://fixture.test/\(path)")!, maximumBytes: 64,
      configuration: stubConfiguration())
  }
}

@Test func nativeHTTPCancellationWhileWaiting() async throws {
  let token = try CancellationToken()
  let cancellation = Task {
    try await Task.sleep(for: .milliseconds(150))
    token.cancel()
  }
  defer { cancellation.cancel() }
  await #expect(throws: CancellationError.self) {
    try await HTTPData.get(
      URL(string: "https://fixture.test/stall")!, maximumBytes: 64, cancellation: token,
      configuration: stubConfiguration())
  }
}

@Test(arguments: [
  "http://fixture.test/ok", "https://user@fixture.test/ok", "https://fixture.test/ok#part",
])
func nativeHTTPRejectsUnsafeURL(_ value: String) async {
  await #expect(throws: (any Error).self) {
    try await HTTPData.get(
      URL(string: value)!, maximumBytes: 64, configuration: stubConfiguration())
  }
}

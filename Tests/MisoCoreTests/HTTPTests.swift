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

private func stubConfiguration() -> URLSessionConfiguration {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubHTTPProtocol.self]
  return configuration
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

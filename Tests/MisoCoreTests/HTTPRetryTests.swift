import Foundation
import Testing

@testable import MisoCore

private actor HTTPRetryDelays {
  var values: [Duration] = []
  func append(_ value: Duration) { values.append(value) }
}

@Test(arguments: [false, true])
func httpRetryStopsAfterTenAttempts(succeeds: Bool) async throws {
  let delays = HTTPRetryDelays()
  var attempts = 0
  do {
    let result = try await HTTPRetry.run(sleep: { await delays.append($0) }) {
      attempts += 1
      if succeeds && attempts == 10 { return 42 }
      throw HTTPRetry.StatusError(status: 502, retryAfter: 0)
    }
    #expect(succeeds && result == 42)
  } catch {
    #expect(!succeeds)
    #expect(
      error.localizedDescription == "HTTPS request failed with status 502 after 10 attempt(s)")
  }
  #expect(attempts == 10)
  #expect(await delays.values == [2, 4, 8, 16, 32, 64, 128, 256, 300].map { .seconds($0) })
}

@Test func httpRetryHonorsServerDelayAndRejectsPermanentErrors() async throws {
  let now = Date(timeIntervalSince1970: 0)
  for value in ["120", "Thu, 01 Jan 1970 00:02:00 GMT"] {
    let response = HTTPURLResponse(
      url: URL(string: "https://fixture.test/retry")!, statusCode: 429,
      httpVersion: nil, headerFields: ["Retry-After": value])!
    let delays = HTTPRetryDelays()
    var attempts = 0
    try await HTTPRetry.run(sleep: { await delays.append($0) }) {
      attempts += 1
      if attempts == 1 { try HTTPRetry.requireSuccess(response, now: now) }
    }
    #expect(attempts == 2)
    #expect(await delays.values == [.seconds(120)])
  }
  for error: any Error in [
    HTTPRetry.StatusError(status: 403, retryAfter: 0),
    HTTPRetry.StatusError(status: 404, retryAfter: 0),
    URLError(.serverCertificateUntrusted), CancellationError(),
    MisoError.invalid("Payload exceeds size limit"),
  ] {
    var attempts = 0
    await #expect(throws: (any Error).self) {
      try await HTTPRetry.run(sleep: { _ in Issue.record("Permanent errors must not retry") }) {
        attempts += 1
        throw error
      }
    }
    #expect(attempts == 1)
  }
}

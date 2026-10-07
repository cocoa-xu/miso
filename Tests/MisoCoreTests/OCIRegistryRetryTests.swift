import Foundation
import Testing

@testable import MisoCore

private actor RetryDelays {
  var values: [Duration] = []
  func append(_ value: Duration) { values.append(value) }
}

@Test(arguments: [true, false])
func registryRetriesUpToTenAttemptsWithBoundedBackoff(succeeds: Bool) async throws {
  let registry = try OCIRegistry(
    reference: OCIReference("ghcr.io/fixture/image:test"), username: nil, password: nil,
    pushing: false, cancellation: CancellationToken())
  let delays = RetryDelays()
  var attempts = 0
  do {
    let result = try await registry.retry(
      progress: nil, id: UUID(), sleep: { await delays.append($0) },
      body: {
        attempts += 1
        if succeeds && attempts == 10 { return 42 }
        throw OCIRegistryError(status: -1001, retryAfter: 2)
      })
    #expect(succeeds && result == 42)
  } catch let error as OCIRegistryError {
    #expect(!succeeds && error.status == -1001)
  }
  #expect(attempts == 10)
  #expect(await delays.values == [2, 4, 8, 16, 32, 64, 128, 256, 300].map { .seconds($0) })
}

@Test func registryRetryHonorsServerDelayAndCancellation() async throws {
  let token = try CancellationToken()
  let registry = try OCIRegistry(
    reference: OCIReference("ghcr.io/fixture/image:test"), username: nil, password: nil,
    pushing: false, cancellation: token)
  let response = HTTPURLResponse(
    url: URL(string: "https://ghcr.io/v2/fixture/image/tags/list")!, statusCode: 429,
    httpVersion: nil, headerFields: ["Retry-After": "120"])!
  let delays = RetryDelays()
  var attempts = 0
  await #expect(throws: CancellationError.self) {
    try await registry.retry(
      progress: nil, id: UUID(),
      sleep: {
        await delays.append($0)
        token.cancel()
        try await Task.sleep(for: .seconds(10))
      },
      body: {
        attempts += 1
        try registry.require(response, codes: [200])
      })
  }
  #expect(attempts == 1)
  #expect(await delays.values == [.seconds(120)])
}

@Test(arguments: [401, 403, 404, -999, -1000, -1202])
func registryDoesNotRetryPermanentFailures(status: Int) async throws {
  let registry = try OCIRegistry(
    reference: OCIReference("ghcr.io/fixture/image:test"), username: nil, password: nil,
    pushing: false, cancellation: CancellationToken())
  var attempts = 0
  await #expect(throws: OCIRegistryError.self) {
    try await registry.retry(
      progress: nil, id: UUID(),
      sleep: { _ in
        Issue.record("A permanent failure must not wait for another attempt")
      },
      body: {
        attempts += 1
        throw OCIRegistryError(status: status, retryAfter: 1)
      })
  }
  #expect(attempts == 1)
}

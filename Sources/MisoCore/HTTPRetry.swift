import Foundation

enum HTTPRetry {
  struct StatusError: LocalizedError {
    let status: Int
    let retryAfter: Int
    var errorDescription: String? { "HTTPS request failed with status \(status)" }
  }

  static func isRetryable(_ status: Int) -> Bool {
    [-1001, -1003, -1004, -1005, -1006, -1009, 408, 429, 500, 502, 503, 504].contains(status)
  }

  static func delay(attempt: Int, retryAfter: Int) -> Int {
    min(300, max(retryAfter, 2 << (attempt - 1)))
  }

  static func requireSuccess(_ response: HTTPURLResponse, now: Date = Date()) throws {
    guard response.statusCode != 200 else { return }
    let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
    var seconds = Int(value) ?? 0
    if seconds == 0 {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
      if let date = formatter.date(from: value) {
        seconds = Int(min(300, max(0, date.timeIntervalSince(now))))
      }
    }
    throw StatusError(status: response.statusCode, retryAfter: min(300, max(0, seconds)))
  }

  static func run<T>(
    cancellation: CancellationToken? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    body: () async throws -> T
  ) async throws -> T {
    for attempt in 1...10 {
      try Task.checkCancellation()
      try cancellation?.check()
      do {
        return try await body()
      } catch {
        try Task.checkCancellation()
        try cancellation?.check()
        let status: Int
        let retryAfter: Int
        if let response = error as? StatusError {
          status = response.status
          retryAfter = response.retryAfter
        } else if let transport = error as? URLError {
          status = transport.errorCode
          retryAfter = 0
        } else {
          throw error
        }
        guard isRetryable(status), attempt < 10 else {
          if error is StatusError {
            throw MisoError.invalid(
              "HTTPS request failed with status \(status) after \(attempt) attempt(s)")
          }
          throw error
        }
        let seconds = delay(attempt: attempt, retryAfter: retryAfter)
        BuildProgress.write(
          "Retry HTTPS download in \(seconds)s (attempt \(attempt + 1)/10, status \(status))")
        try await sleep(.seconds(seconds))
      }
    }
    throw MisoError.invalid("HTTPS retry limit exceeded")
  }
}

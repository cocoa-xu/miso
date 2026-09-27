import Foundation

enum HTTPFile {
  private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    let gate: HTTPData.RedirectGate

    init(url: URL, maximumBytes: Int64, redirects: HTTPData.RedirectPolicy) {
      self.maximumBytes = maximumBytes
      gate = HTTPData.RedirectGate(source: url, policy: redirects)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      gate.urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
      totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
      if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
        downloadTask.cancel()
      }
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask,
      didFinishDownloadingTo location: URL
    ) {}
  }

  static func validate(_ url: URL, maximumBytes: UInt64) throws {
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      url.fragment == nil, url.query == nil, url.port == nil || url.port == 443,
      (1...(512 << 20)).contains(maximumBytes)
    else { throw MisoError.invalid("Invalid HTTPS payload request") }
  }

  static func get(
    _ url: URL, to output: URL, maximumBytes: UInt64,
    cancellation: CancellationToken? = nil,
    redirects: HTTPData.RedirectPolicy = .reject,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws {
    try await fetch(
      url, to: output, maximumBytes: maximumBytes, body: nil, contentType: nil,
      cancellation: cancellation, redirects: redirects, gitProtocolV2: false,
      configuration: configuration)
  }

  static func post(
    _ url: URL, body: Data, contentType: String, to output: URL, maximumBytes: UInt64,
    cancellation: CancellationToken? = nil,
    gitProtocolV2: Bool = false,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws {
    guard !body.isEmpty, body.count <= 4 << 20,
      contentType.range(of: #"\Aapplication/[a-z0-9.+-]{1,80}\z"#, options: .regularExpression)
        != nil
    else { throw MisoError.invalid("Invalid HTTPS payload request body or content type") }
    try await fetch(
      url, to: output, maximumBytes: maximumBytes, body: body, contentType: contentType,
      cancellation: cancellation, redirects: .reject, gitProtocolV2: gitProtocolV2,
      configuration: configuration)
  }

  private static func fetch(
    _ url: URL, to output: URL, maximumBytes: UInt64, body: Data?, contentType: String?,
    cancellation: CancellationToken?, redirects: HTTPData.RedirectPolicy,
    gitProtocolV2: Bool,
    configuration: URLSessionConfiguration
  ) async throws {
    try validate(url, maximumBytes: maximumBytes)
    try cancellation?.check()
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 300
    let delegate = Delegate(url: url, maximumBytes: Int64(maximumBytes), redirects: redirects)
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = body == nil ? "GET" : "POST"
    if gitProtocolV2 { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
    request.httpBody = body
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("miso", forHTTPHeaderField: "User-Agent")
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [request] in
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
          let destination = response.url,
          destination == url || redirects.permits(from: url, to: destination),
          response.expectedContentLength <= maximumBytes
        else { throw MisoError.invalid("Unexpected HTTPS payload response") }
        try Artifacts.copy(
          temporary, to: output, maximumBytes: maximumBytes,
          cancellation: cancellation)
      }
      group.addTask {
        while true {
          try Task.checkCancellation()
          try cancellation?.check()
          try await Task.sleep(for: .milliseconds(50))
        }
      }
      defer {
        group.cancelAll()
        session.invalidateAndCancel()
      }
      try await group.next()
    }
  }
}

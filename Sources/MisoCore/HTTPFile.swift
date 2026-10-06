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

  static func validate(
    _ url: URL, maximumBytes: UInt64, appleAsset: Bool = false, appleRestore: Bool = false,
    xcodeArchive: Bool = false
  ) throws {
    if appleAsset {
      guard AppleAssetCatalog.isArchiveURL(url) else {
        throw MisoError.invalid("Invalid Apple asset archive URL")
      }
    }
    if appleRestore {
      guard url.host == "updates.cdn-apple.com", url.path.hasSuffix("_Restore.ipsw") else {
        throw MisoError.invalid("Invalid Apple restore archive URL")
      }
    }
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      url.fragment == nil, url.query == nil, url.port == nil || url.port == 443,
      (1...(appleAsset || appleRestore || xcodeArchive ? 32 << 30 : 2 << 30)).contains(maximumBytes)
    else { throw MisoError.invalid("Invalid HTTPS payload request") }
  }

  static func xcodeArchive(
    _ url: URL, to output: URL, cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws {
    do {
      try await fetch(
        url, to: output, maximumBytes: 32 << 30, body: nil, contentType: nil,
        cancellation: cancellation, redirects: .reject, gitProtocolV2: false,
        authorization: nil, configuration: configuration, xcodeArchive: true)
    } catch let error as MisoError {
      throw error
    } catch {
      try cancellation?.check()
      if error is CancellationError { throw error }
      throw MisoError.invalid("Xcode download failed (error code \((error as NSError).code))")
    }
  }

  static func restoreArchive(
    _ url: URL, to output: URL, cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws {
    try await fetch(
      url, to: output, maximumBytes: 32 << 30, body: nil, contentType: nil,
      cancellation: cancellation, redirects: .reject, gitProtocolV2: false,
      authorization: nil, configuration: configuration, appleRestore: true)
  }

  static func appleAsset(
    _ url: URL, to output: URL, maximumBytes: UInt64,
    cancellation: CancellationToken? = nil
  ) async throws {
    try await fetch(
      url, to: output, maximumBytes: maximumBytes, body: nil, contentType: nil,
      cancellation: cancellation, redirects: .reject, gitProtocolV2: false,
      authorization: nil, configuration: .ephemeral, appleAsset: true)
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
      authorization: nil, configuration: configuration)
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
      authorization: nil, configuration: configuration)
  }

  static func homebrewBlob(
    _ sha256: String, to output: URL, cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws {
    try await homebrewBlob(
      HomebrewRegistry.blob(name: "portable-ruby", sha256: sha256),
      to: output, maximumBytes: 64 << 20, cancellation: cancellation,
      configuration: configuration)
  }

  static func homebrewBlob(
    _ url: URL, to output: URL, maximumBytes: UInt64,
    cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws {
    guard HomebrewRegistry.permits(url) else {
      throw MisoError.invalid("Invalid Homebrew bottle URL")
    }
    try await fetch(
      url, to: output, maximumBytes: maximumBytes, body: nil, contentType: nil,
      cancellation: cancellation, redirects: .homebrewBlob, gitProtocolV2: false,
      authorization: "Bearer QQ==", configuration: configuration)
  }

  private static func fetch(
    _ url: URL, to output: URL, maximumBytes: UInt64, body: Data?, contentType: String?,
    cancellation: CancellationToken?, redirects: HTTPData.RedirectPolicy,
    gitProtocolV2: Bool, authorization: String?,
    configuration: URLSessionConfiguration, appleAsset: Bool = false, appleRestore: Bool = false,
    xcodeArchive: Bool = false
  ) async throws {
    try validate(
      url, maximumBytes: maximumBytes, appleAsset: appleAsset, appleRestore: appleRestore,
      xcodeArchive: xcodeArchive)
    try cancellation?.check()
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource =
      appleAsset || appleRestore || xcodeArchive ? 3600 : 300
    let delegate = Delegate(url: url, maximumBytes: Int64(maximumBytes), redirects: redirects)
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = body == nil ? "GET" : "POST"
    if gitProtocolV2 { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
    request.httpBody = body
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("miso", forHTTPHeaderField: "User-Agent")
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [request] in
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse else {
          throw MisoError.invalid("Expected an HTTPS payload response")
        }
        guard response.statusCode == 200 else {
          throw MisoError.invalid("HTTPS payload request failed with status \(response.statusCode)")
        }
        guard let destination = response.url,
          destination == url || redirects.permits(from: url, to: destination)
        else { throw MisoError.invalid("HTTPS payload response destination changed") }
        guard response.expectedContentLength <= maximumBytes else {
          throw MisoError.invalid("HTTPS payload exceeds size limit")
        }
        if appleRestore || xcodeArchive {
          try Artifacts.moveDownload(
            temporary, to: output, maximumBytes: maximumBytes, cancellation: cancellation)
        } else {
          try Artifacts.copy(
            temporary, to: output, maximumBytes: maximumBytes, cancellation: cancellation)
        }
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

import Foundation

enum HTTPData {
  enum RedirectPolicy: Sendable {
    case reject, appleKeys, githubRelease

    func permits(from source: URL, to destination: URL) -> Bool {
      switch self {
      case .reject: return false
      case .appleKeys:
        return HTTPData.isAppleKeyURL(source) && HTTPData.isAppleKeyURL(destination)
          && source.path == destination.path
      case .githubRelease:
        return HTTPData.isGitHubReleaseURL(source) && destination.scheme == "https"
          && destination.host == "release-assets.githubusercontent.com"
          && destination.user == nil && destination.password == nil
          && destination.fragment == nil && destination.port == nil
          && destination.absoluteString.utf8.count <= 16_384
          && destination.path.hasPrefix("/github-production-release-asset/")
      }
    }
  }

  final class RedirectGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let source: URL
    private let policy: RedirectPolicy
    private let lock = NSLock()
    private var count = 0

    init(source: URL, policy: RedirectPolicy) {
      self.source = source
      self.policy = policy
    }

    func accept(_ destination: URL) -> Bool {
      lock.withLock {
        guard count < 3, policy.permits(from: source, to: destination) else { return false }
        count += 1
        return true
      }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      guard request.httpMethod == "GET", let url = request.url, accept(url) else {
        completionHandler(nil)
        return
      }
      completionHandler(request)
    }
  }

  static func isAppleKeyURL(_ url: URL) -> Bool {
    let hosts: Set<String> = ["wkms-public.apple.com", "fcs-keys-pub-prod.cdn-apple.com"]
    return url.scheme == "https" && hosts.contains(url.host?.lowercased() ?? "")
      && url.user == nil && url.password == nil && url.fragment == nil && url.query == nil
      && (url.port == nil || url.port == 443) && url.path.hasPrefix("/fcs-keys/")
      && url.path.count > 10 && url.path.count <= 1024
  }

  static func isGitHubReleaseURL(_ url: URL) -> Bool {
    url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
      && url.query == nil && url.fragment == nil && url.port == nil
      && url.path.range(
        of:
          #"\A/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z"#,
        options: .regularExpression) != nil
  }

  static func get(
    _ url: URL, maximumBytes: Int, cancellation: CancellationToken? = nil,
    redirects: RedirectPolicy = .reject,
    accept: String? = nil,
    gitProtocolV2: Bool = false,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Data {
    try await fetch(
      url, method: "GET", body: nil, maximumBytes: maximumBytes,
      cancellation: cancellation, redirects: redirects, accept: accept,
      gitProtocolV2: gitProtocolV2, configuration: configuration
    )
  }

  static func post(
    _ url: URL, body: Data, maximumBytes: Int, cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Data {
    guard !body.isEmpty, body.count <= 4 << 20 else {
      throw MisoError.invalid("Invalid HTTPS request size")
    }
    return try await fetch(
      url, method: "POST", body: body, maximumBytes: maximumBytes,
      cancellation: cancellation, redirects: .reject, accept: nil,
      gitProtocolV2: false, configuration: configuration)
  }

  private static func fetch(
    _ url: URL, method: String, body: Data?, maximumBytes: Int, cancellation: CancellationToken?,
    redirects: RedirectPolicy, accept: String?, gitProtocolV2: Bool,
    configuration: URLSessionConfiguration
  ) async throws -> Data {
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      url.fragment == nil, maximumBytes > 0, maximumBytes <= 8 << 20
    else {
      throw MisoError.invalid("Invalid HTTPS request")
    }
    try cancellation?.check()
    if let accept {
      guard !accept.isEmpty, accept.utf8.count <= 128,
        accept.utf8.allSatisfy({ (32...126).contains($0) })
      else { throw MisoError.invalid("Invalid HTTP Accept header") }
    }
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = method
    if gitProtocolV2 { request.setValue("version=2", forHTTPHeaderField: "Git-Protocol") }
    request.httpBody = body
    if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
    if body != nil { request.setValue("text/xml", forHTTPHeaderField: "Content-Type") }
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(body == nil ? "miso" : "InetURL/1.0", forHTTPHeaderField: "User-Agent")
    return try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { [request] in
        let (bytes, response) = try await session.bytes(
          for: request, delegate: RedirectGate(source: url, policy: redirects))
        guard let response = response as? HTTPURLResponse else {
          throw MisoError.invalid("Expected an HTTPS response")
        }
        guard response.statusCode == 200 else {
          throw MisoError.invalid("HTTPS request failed with status \(response.statusCode)")
        }
        guard let destination = response.url,
          destination == url || redirects.permits(from: url, to: destination)
        else {
          throw MisoError.invalid("HTTPS response destination changed")
        }
        guard response.expectedContentLength <= maximumBytes else {
          throw MisoError.invalid("HTTPS response exceeds size limit")
        }
        var result = Data()
        for try await byte in bytes {
          guard result.count < maximumBytes else {
            throw MisoError.invalid("HTTPS response exceeds size limit")
          }
          result.append(byte)
        }
        guard !result.isEmpty else { throw MisoError.invalid("Empty HTTPS response") }
        return result
      }
      if let cancellation {
        group.addTask {
          while true {
            try cancellation.check()
            try await Task.sleep(for: .milliseconds(100))
          }
        }
      }
      defer {
        group.cancelAll()
        session.invalidateAndCancel()
      }
      guard let result = try await group.next() else { throw CancellationError() }
      try cancellation?.check()
      return result
    }
  }
}

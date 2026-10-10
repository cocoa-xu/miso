import Foundation

struct OCIRegistryError: LocalizedError {
  let status: Int
  let retryAfter: Int
  var errorDescription: String? { "GHCR request failed (status \(status))" }
  var retryable: Bool {
    HTTPRetry.isRetryable(status)
  }
}

final class OCIRegistry: @unchecked Sendable {
  struct Response {
    let data: Data
    let http: HTTPURLResponse
  }

  class Observer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let blobRedirects: Bool
    let progress: TransferProgress?
    let id: UUID
    private let lock = NSLock()
    private var redirects = 0

    init(blobRedirects: Bool, progress: TransferProgress?, id: UUID) {
      self.blobRedirects = blobRedirects
      self.progress = progress
      self.id = id
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      guard blobRedirects, request.httpMethod == "GET" || request.httpMethod == "HEAD",
        let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
        url.port == nil || url.port == 443, url.fragment == nil,
        ["ghcr.io", "pkg-containers.githubusercontent.com"].contains(url.host),
        lock.withLock({
          redirects += 1
          return redirects <= 3
        })
      else {
        completionHandler(nil)
        return
      }
      var forwarded = request
      if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
        forwarded.setValue(range, forHTTPHeaderField: "Range")
        forwarded.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      }
      if url.host != "ghcr.io" { forwarded.setValue(nil, forHTTPHeaderField: "Authorization") }
      completionHandler(forwarded)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
      totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) { progress?.update(id, bytes: totalBytesSent) }

  }

  let reference: OCIReference
  private let session: URLSession
  private let username: String?
  private let password: String?
  private let pushing: Bool
  private let cancellation: CancellationToken
  private let lock = NSLock()
  private var token: String?

  init(
    reference: OCIReference, username: String?, password: String?, pushing: Bool,
    cancellation: CancellationToken, configuration: URLSessionConfiguration = .ephemeral
  ) throws {
    guard (username == nil) == (password == nil),
      !pushing || username != nil,
      [username, password].compactMap({ $0 }).allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 16_384 && !$0.contains("\n") && !$0.contains("\r")
      }), !(username?.contains(":") ?? false)
    else { throw MisoError.invalid("Set MISO_REGISTRY_USERNAME and MISO_REGISTRY_PASSWORD") }
    self.reference = reference
    self.username = username
    self.password = password
    self.pushing = pushing
    self.cancellation = cancellation
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 3600
    configuration.httpMaximumConnectionsPerHost = 16
    session = URLSession(configuration: configuration)
  }

  deinit { session.invalidateAndCancel() }

  private func authenticate() async throws {
    var url = URLComponents(string: "https://ghcr.io/token")!
    url.queryItems = [
      URLQueryItem(name: "service", value: "ghcr.io"),
      URLQueryItem(
        name: "scope", value: "repository:\(reference.repository):\(pushing ? "pull,push" : "pull")"
      ),
    ]
    var request = URLRequest(url: url.url!)
    if let username, let password {
      request.setValue(
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString(),
        forHTTPHeaderField: "Authorization")
    }
    let response = try await send(request)
    try require(response.http, codes: [200])
    struct Token: Decodable { let token: String }
    let value = try JSONDecoder().decode(Token.self, from: response.data).token
    guard !value.isEmpty, value.utf8.count <= 64 << 10,
      value.utf8.allSatisfy({ (33...126).contains($0) })
    else { throw MisoError.invalid("Invalid GHCR authorization token") }
    lock.withLock { token = value }
  }

  func request(
    _ method: String, url: URL, data: Data? = nil, file: URL? = nil,
    contentType: String? = nil, progress: TransferProgress? = nil, id: UUID = UUID()
  ) async throws -> Response {
    guard url.scheme == "https", url.host == "ghcr.io", url.port == nil || url.port == 443,
      url.user == nil, url.password == nil, url.fragment == nil
    else { throw MisoError.invalid("Invalid GHCR request destination") }
    if lock.withLock({ token == nil }) { try await authenticate() }
    for attempt in 0...1 {
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
      request.httpMethod = method
      request.setValue(
        lock.withLock { "Bearer " + (token ?? "") }, forHTTPHeaderField: "Authorization")
      request.setValue("miso", forHTTPHeaderField: "User-Agent")
      request.setValue(OCIManifest.manifestType, forHTTPHeaderField: "Accept")
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      let response = try await send(request, data: data, file: file, progress: progress, id: id)
      if response.http.statusCode != 401 || attempt == 1 { return response }
      progress?.reset(id)
      try await authenticate()
    }
    throw MisoError.invalid("GHCR authorization failed")
  }

  private func send(
    _ request: URLRequest, data: Data? = nil, file: URL? = nil,
    progress: TransferProgress? = nil, id: UUID = UUID()
  ) async throws -> Response {
    try cancellation.check()
    let observer = Observer(
      blobRedirects: request.httpMethod == "HEAD", progress: progress, id: id)
    do {
      let (bytes, response): (Data, URLResponse) = try await cancellable {
        if let file {
          return try await self.session.upload(for: request, fromFile: file, delegate: observer)
        }
        if let data {
          return try await self.session.upload(for: request, from: data, delegate: observer)
        }
        return try await self.session.data(for: request, delegate: observer)
      }
      guard bytes.count <= 16 << 20, let http = response as? HTTPURLResponse else {
        throw MisoError.invalid("Invalid GHCR response")
      }
      return Response(data: bytes, http: http)
    } catch let error as URLError {
      try cancellation.check()
      throw OCIRegistryError(status: error.errorCode, retryAfter: 2)
    }
  }

  func download(
    _ blob: OCIDescriptor, to file: URL, progress: TransferProgress, id: UUID
  ) async throws {
    let partial = file.appendingPathExtension("partial")
    do {
      if lock.withLock({ token == nil }) { try await authenticate() }
      for attempt in 0...1 {
        let observer = try OCIBlobDownload(
          destination: partial, progress: progress, id: id, maximumBytes: Int64(blob.size))
        if observer.offset == Int64(blob.size) {
          try observer.close()
          try cancellation.check()
          try FileManager.default.moveItem(at: partial, to: file)
          return
        }
        var request = URLRequest(url: reference.url("blobs/\(blob.digest)"))
        request.setValue(
          lock.withLock { "Bearer " + (token ?? "") }, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if observer.offset > 0 {
          request.setValue("bytes=\(observer.offset)-", forHTTPHeaderField: "Range")
          BuildProgress.write(
            "Resume OCI blob \(blob.digest.prefix(19)) at \(TransferProgress.size(Double(observer.offset))) / \(TransferProgress.size(Double(blob.size)))"
          )
        }
        let task = session.dataTask(with: request)
        task.delegate = observer
        do {
          try await cancellable { try await observer.start(task) }
        } catch let error as URLError {
          try cancellation.check()
          throw OCIRegistryError(status: error.errorCode, retryAfter: 2)
        } catch let error as OCIRegistryError where error.status == 401 && attempt == 0 {
          try await authenticate()
          continue
        }
        try cancellation.check()
        try FileManager.default.moveItem(at: partial, to: file)
        return
      }
    } catch {
      if !((error as? OCIRegistryError)?.retryable ?? false) {
        try? FileManager.default.removeItem(at: partial)
      }
      throw error
    }
  }

  func require(_ response: HTTPURLResponse, codes: Set<Int>) throws {
    guard codes.contains(response.statusCode) else {
      throw OCIRegistryError(
        status: response.statusCode,
        retryAfter: min(
          300, max(1, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "2") ?? 2)))
    }
  }

  func checkDigest(_ response: HTTPURLResponse, expected: String) throws {
    if let actual = response.value(forHTTPHeaderField: "Docker-Content-Digest"), actual != expected
    {
      throw MisoError.invalid("Registry returned an unexpected content digest")
    }
  }

  func contains(_ blob: OCIDescriptor) async throws -> Bool {
    let response = try await request("HEAD", url: reference.url("blobs/\(blob.digest)"))
    if response.http.statusCode == 404 { return false }
    try require(response.http, codes: [200])
    try checkDigest(response.http, expected: blob.digest)
    if let size = response.http.value(forHTTPHeaderField: "Content-Length"),
      UInt64(size) != blob.size
    {
      throw MisoError.invalid("Registry blob size differs from its descriptor")
    }
    return true
  }

  func uploadLocation(_ response: HTTPURLResponse) throws -> URL {
    guard let value = response.value(forHTTPHeaderField: "Location"),
      let url = URL(string: value, relativeTo: response.url)?.absoluteURL,
      url.scheme == "https", url.host == "ghcr.io", url.port == nil || url.port == 443,
      url.user == nil, url.password == nil, url.fragment == nil
    else { throw MisoError.invalid("Invalid GHCR upload location") }
    return url
  }

  func retry<T>(
    progress: TransferProgress?, id: UUID,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    body: () async throws -> T
  ) async throws -> T {
    let maximumAttempts = 10
    for attempt in 1...maximumAttempts {
      try cancellation.check()
      do { return try await body() } catch let error as OCIRegistryError
        where error.retryable && attempt < maximumAttempts
      {
        progress?.reset(id)
        let delay = HTTPRetry.delay(attempt: attempt, retryAfter: error.retryAfter)
        BuildProgress.write(
          "Retry registry transfer in \(delay)s (attempt \(attempt + 1)/\(maximumAttempts), status \(error.status))"
        )
        try await cancellable {
          try await sleep(.seconds(delay))
        }
      }
    }
    throw MisoError.invalid("GHCR retry limit exceeded")
  }

  private func cancellable<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask(operation: body)
      group.addTask {
        while true {
          try self.cancellation.check()
          try await Task.sleep(for: .milliseconds(100))
        }
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }
}

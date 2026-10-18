import Foundation

final class HTTPFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let file: FileHandle
  private let source: URL
  private let maximumBytes: Int64
  private let redirects: HTTPData.RedirectPolicy
  private let gate: HTTPData.RedirectGate
  private var received: Int64 = 0
  private var expected: Int64 = -1
  private var failure: (any Error)?
  private let completionLock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var result: Result<Void, any Error>?

  init(source: URL, destination: URL, maximumBytes: Int64, redirects: HTTPData.RedirectPolicy)
    throws
  {
    file = try SafeFile.create(destination)
    self.source = source
    self.maximumBytes = maximumBytes
    self.redirects = redirects
    gate = HTTPData.RedirectGate(source: source, policy: redirects)
  }

  deinit { try? file.close() }

  func start(_ task: URLSessionDataTask) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = completionLock.withLock {
          if let result = self.result { return result }
          self.continuation = continuation
          return nil
        }
        if let result { continuation.resume(with: result) }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
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
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    do {
      guard let response = response as? HTTPURLResponse else {
        throw MisoError.invalid("Expected an HTTPS payload response")
      }
      try HTTPRetry.requireSuccess(response)
      guard let destination = response.url,
        destination == source || redirects.permits(from: source, to: destination)
      else { throw MisoError.invalid("HTTPS payload response destination changed") }
      guard response.expectedContentLength <= maximumBytes else {
        throw MisoError.invalid("HTTPS payload exceeds size limit")
      }
      expected = response.expectedContentLength
      completionHandler(.allow)
    } catch {
      failure = error
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    do {
      guard Int64(data.count) <= maximumBytes - received else {
        throw MisoError.invalid("HTTPS payload exceeds size limit")
      }
      try file.write(contentsOf: data)
      received += Int64(data.count)
    } catch {
      failure = error
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    do { try file.close() } catch { failure = failure ?? error }
    let result: Result<Void, any Error>
    if let error = failure ?? error {
      result = .failure(error)
    } else if expected >= 0, received != expected {
      result = .failure(URLError(.networkConnectionLost))
    } else if received == 0 {
      result = .failure(MisoError.invalid("Empty HTTPS payload"))
    } else {
      result = .success(())
    }
    let continuation = completionLock.withLock {
      self.result = result
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }
}

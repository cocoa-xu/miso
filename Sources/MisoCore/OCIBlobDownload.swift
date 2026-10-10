import Foundation

final class OCIBlobDownload: OCIRegistry.Observer, URLSessionDataDelegate, @unchecked Sendable {
  let offset: Int64
  private let file: FileHandle
  private let maximumBytes: Int64
  private var received: Int64
  private var failure: (any Error)?
  private let completionLock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var result: Result<Void, any Error>?

  init(destination: URL, progress: TransferProgress, id: UUID, maximumBytes: Int64) throws {
    file =
      try FileManager.default.fileExists(atPath: destination.path)
      ? SafeFile.openRegular(destination, writable: true) : SafeFile.create(destination)
    offset = Int64(try SafeFile.size(file))
    guard offset <= maximumBytes else {
      throw MisoError.invalid("Partial OCI blob exceeds its declared size")
    }
    try file.seek(toOffset: UInt64(offset))
    received = offset
    self.maximumBytes = maximumBytes
    super.init(blobRedirects: true, progress: progress, id: id)
  }

  deinit { try? file.close() }

  func close() throws { try file.close() }

  func start(_ task: URLSessionDataTask) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result = completionLock.withLock {
          self.continuation = continuation
          return self.result
        }
        if let result { continuation.resume(with: result) }
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    do {
      guard let response = response as? HTTPURLResponse else {
        throw MisoError.invalid("Invalid GHCR response")
      }
      switch response.statusCode {
      case 200:
        if offset > 0 {
          try file.truncate(atOffset: 0)
          try file.seek(toOffset: 0)
          received = 0
          progress?.reset(id)
          BuildProgress.write("Registry ignored the byte range; restarting this OCI blob")
        }
      case 206:
        guard offset > 0,
          response.value(forHTTPHeaderField: "Content-Range")
            == "bytes \(offset)-\(maximumBytes - 1)/\(maximumBytes)"
        else { throw MisoError.invalid("OCI blob response has an invalid Content-Range") }
      default:
        throw OCIRegistryError(
          status: response.statusCode,
          retryAfter: min(
            300, max(1, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "2") ?? 2)))
      }
      if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
        encoding.lowercased() != "identity"
      {
        throw MisoError.invalid("OCI blob response has an unexpected Content-Encoding")
      }
      if let length = response.value(forHTTPHeaderField: "Content-Length"),
        Int64(length) != maximumBytes - received
      {
        throw MisoError.invalid("OCI blob response size differs from manifest")
      }
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
        throw MisoError.invalid("Downloaded OCI blob exceeds its declared size")
      }
      try file.write(contentsOf: data)
      received += Int64(data.count)
      progress?.update(id, bytes: received)
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
    } else if received != maximumBytes {
      result = .failure(
        OCIRegistryError(status: URLError.networkConnectionLost.rawValue, retryAfter: 2))
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

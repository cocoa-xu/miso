import Darwin
import Dispatch
import MisoCore

final class CancellationScope {
  let token: CancellationToken
  private var sources: [any DispatchSourceSignal] = []
  private var previous: [(Int32, sigaction)] = []

  init() throws {
    token = try CancellationToken()
    for number in [SIGINT, SIGTERM] {
      var old = sigaction()
      var ignored = sigaction()
      ignored.__sigaction_u.__sa_handler = SIG_IGN
      sigemptyset(&ignored.sa_mask)
      guard sigaction(number, &ignored, &old) == 0 else {
        restore()
        throw MisoError.system("Install cancellation handler", errno)
      }
      previous.append((number, old))
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
      source.setEventHandler { [token] in token.cancel() }
      source.resume()
      sources.append(source)
    }
  }

  deinit { restore() }

  private func restore() {
    for source in sources { source.cancel() }
    for (number, value) in previous.reversed() {
      var action = value
      _ = sigaction(number, &action, nil)
    }
    sources.removeAll()
    previous.removeAll()
  }
}

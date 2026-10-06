import Foundation

enum BuildProgress {
  @discardableResult
  static func run<T>(_ title: String?, operation: () throws -> T) rethrows -> T {
    guard let title else { return try operation() }
    let start = ProcessInfo.processInfo.systemUptime
    write("\(title): started")
    func finish(_ status: String) {
      let seconds = Int(ProcessInfo.processInfo.systemUptime - start)
      write("\(title): \(status) (\(seconds / 60)m \(seconds % 60)s)")
    }
    do {
      let result = try operation()
      finish("completed")
      return result
    } catch {
      finish("failed")
      throw error
    }
  }

  static func write(_ message: String) {
    FileHandle.standardError.write(Data(("[miso] " + message + "\n").utf8))
  }

  final class Relay: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let queue = DispatchQueue(label: "miso.progress")
    private let timer: DispatchSourceTimer

    init(file: URL, output: FileHandle = .standardError) throws {
      input = try SafeFile.openRegular(file)
      self.output = output
      timer = DispatchSource.makeTimerSource(queue: queue)
      timer.setEventHandler { [weak self] in self?.drain() }
      timer.schedule(deadline: .now(), repeating: .seconds(1))
      timer.resume()
    }

    func finish() {
      queue.sync {
        timer.cancel()
        drain()
        try? input.close()
      }
    }

    private func drain() {
      while let data = try? input.read(upToCount: 64 << 10), !data.isEmpty {
        try? output.write(contentsOf: data)
      }
    }
  }
}

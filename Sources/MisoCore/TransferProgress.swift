import Foundation

struct TransferRate {
  private var samples: [(time: TimeInterval, bytes: Int64)]
  private(set) var bytes: Int64 = 0

  init(now: TimeInterval) { samples = [(now, 0)] }

  mutating func record(_ count: Int64, now: TimeInterval) {
    bytes += max(0, count)
    if let last = samples.last, now - last.time >= 1 {
      samples.append((now, bytes))
    }
    while samples.count > 2, samples[1].time <= now - 60 { samples.removeFirst() }
  }

  func perSecond(now: TimeInterval) -> Double {
    guard let first = samples.first, now > first.time else { return 0 }
    let start = max(first.time, now - 60)
    var previousBytes = Double(first.bytes)
    if start > first.time, samples.count > 1 {
      let next = samples[1]
      if next.time > first.time {
        let fraction = min(1, (start - first.time) / (next.time - first.time))
        previousBytes += fraction * Double(next.bytes - first.bytes)
      }
    }
    return max(0, (Double(bytes) - previousBytes) / (now - start))
  }
}

final class TransferProgress: @unchecked Sendable {
  private let lock = NSLock()
  private let title: String
  private let total: Int64
  private var completed: Int64 = 0
  private var active: [UUID: Int64] = [:]
  private var rate = TransferRate(now: ProcessInfo.processInfo.systemUptime)
  private var timer: DispatchSourceTimer?

  init(_ title: String, total: Int64) {
    self.title = title
    self.total = total
  }

  var transferredBytes: UInt64 { lock.withLock { UInt64(rate.bytes) } }

  deinit { timer?.cancel() }

  func start() {
    report()
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.setEventHandler { [weak self] in self?.report() }
    timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
    self.timer = timer
    timer.resume()
  }

  func update(_ id: UUID, bytes: Int64) {
    lock.withLock {
      let previous = active[id] ?? 0
      active[id] = max(previous, bytes)
      rate.record(max(0, bytes - previous), now: ProcessInfo.processInfo.systemUptime)
    }
  }

  func complete(_ id: UUID, bytes: Int64) {
    lock.withLock {
      completed += bytes
      active.removeValue(forKey: id)
    }
  }

  func reset(_ id: UUID) { _ = lock.withLock { active.removeValue(forKey: id) } }

  func stop() {
    timer?.cancel()
    timer = nil
    report()
  }

  private func report() {
    let line = lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      rate.record(0, now: now)
      let bytes = min(total, completed + active.values.reduce(0, +))
      let percent = total == 0 ? 100 : 100 * Double(bytes) / Double(total)
      return String(
        format: "%@ %@ / %@ (%.1f%%), %@/s (last 60s)", title,
        Self.size(Double(bytes)), Self.size(Double(total)), percent,
        Self.size(rate.perSecond(now: now)))
    }
    BuildProgress.write(line)
  }

  static func size(_ bytes: Double) -> String {
    var value = max(0, bytes)
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    return String(format: "%.2f %@", value, units[unit])
  }
}

import Darwin
import Foundation

public final class ExecutionJournal {
  public enum Status: String, Codable, Sendable { case running, complete, failed, cancelled }

  public struct CommandRecord: Codable, Sendable {
    public let name: String
    public let arguments: [String]
    public let startedAt: Date
    public let stdout: String
    public let stderr: String
    public let expectedExitCodes: [Int32]?
    public var finishedAt: Date?
    public var result: ProcessReceipt?
    public var error: String?
  }

  public struct Record: Codable, Sendable {
    public let schemaVersion: Int
    public let operation: String
    public let startedAt: Date
    public let host: HostInfo
    public let vmStarted: Bool
    public var status: Status
    public var commands: [CommandRecord]
    public var metadata: [String: JSONValue]
    public var result: JSONValue?
    public var finishedAt: Date?
    public var error: String?
  }

  public let output: URL
  public let cancellation: CancellationToken
  public private(set) var record: Record
  private let lock: FileHandle

  public init(output: URL, operation: String, cancellation: CancellationToken? = nil) throws {
    try Self.validateName(operation)
    self.output = output.standardized
    self.cancellation = try cancellation ?? CancellationToken()
    let host = try HostInfo.current()
    try SafeFile.makeDirectory(self.output)
    lock = try SafeFile.create(self.output.appendingPathComponent(".lock"))
    guard flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw MisoError.system("Lock operation output", errno)
    }
    try SafeFile.makeDirectory(self.output.appendingPathComponent("logs"))
    record = Record(
      schemaVersion: 1, operation: operation, startedAt: Date(), host: host,
      vmStarted: false, status: .running, commands: [], metadata: [:])
    try save()
  }

  deinit { try? lock.close() }

  public func setMetadata(_ name: String, value: some Encodable) throws {
    guard record.status == .running else {
      throw MisoError.invalid("Operation is already finalized")
    }
    record.metadata[name] = try JSONDecoder().decode(JSONValue.self, from: JSON.encode(value))
    try save()
  }

  @discardableResult
  public func measure<T>(_ name: String, body: () throws -> T) throws -> T {
    let started = ProcessInfo.processInfo.systemUptime
    do {
      let value = try body()
      try setMetadata(name, value: ProcessInfo.processInfo.systemUptime - started)
      return value
    } catch {
      try? setMetadata(name, value: ProcessInfo.processInfo.systemUptime - started)
      throw error
    }
  }

  @discardableResult
  public func run(
    _ name: String, _ command: NativeCommand, cleanup: Bool = false, output: URL? = nil,
    expectedExitCodes: Set<Int32> = [0]
  ) throws -> URL {
    try Self.validateName(name)
    guard !expectedExitCodes.isEmpty, expectedExitCodes.allSatisfy({ (0...255).contains($0) })
    else {
      throw MisoError.invalid("Invalid expected command exit codes")
    }
    guard record.status == .running else {
      throw MisoError.invalid("Operation is already finalized")
    }
    let stem = String(format: "%03d-%@", record.commands.count, name)
    let outURL = output ?? self.output.appendingPathComponent("logs/\(stem).stdout")
    guard outURL.path.hasPrefix(self.output.path + "/") else {
      throw MisoError.invalid("Command output must belong to its operation")
    }
    let outName = try SafeFile.relativePath(
      String(outURL.path.dropFirst(self.output.path.count + 1)))
    let errName = "logs/\(stem).stderr"
    let stdout = try SafeFile.create(outURL)
    defer { try? stdout.close() }
    let stderr = try SafeFile.create(self.output.appendingPathComponent(errName))
    defer { try? stderr.close() }
    let index = record.commands.count
    record.commands.append(
      CommandRecord(
        name: name, arguments: command.recordedArguments,
        startedAt: Date(), stdout: outName, stderr: errName,
        expectedExitCodes: expectedExitCodes.sorted()))
    try save()
    do {
      let result = try NativeProcess.run(
        command, stdout: stdout, stderr: stderr,
        cancellation: cleanup ? nil : cancellation)
      record.commands[index].result = result
      record.commands[index].finishedAt = Date()
      try stdout.synchronize()
      try stderr.synchronize()
      try save()
      guard expectedExitCodes.contains(result.exitCode), result.signal == 0,
        !result.timedOut, !result.cancelled
      else {
        throw MisoError.invalid(
          "Command \(name) failed (exit \(result.exitCode), signal \(result.signal), timeout \(result.timedOut), cancelled \(result.cancelled)); see \(errName)"
        )
      }
      return outURL
    } catch {
      record.commands[index].error = error.localizedDescription
      record.commands[index].finishedAt = Date()
      try save()
      throw error
    }
  }

  public func plist<T: Decodable>(
    _ type: T.Type, name: String, command: NativeCommand,
    cleanup: Bool = false
  ) throws -> T {
    let url = try run(name, command, cleanup: cleanup)
    return try PropertyListDecoder().decode(type, from: SafeFile.read(url, limit: 64 << 20))
  }

  public func perform<T: Encodable>(_ body: () throws -> T) throws -> T {
    do {
      let value = try body()
      try finish(value)
      return value
    } catch {
      try fail(error)
      throw error
    }
  }

  public func fail(_ error: any Error) throws {
    guard record.status == .running else {
      throw MisoError.invalid("Operation is already finalized")
    }
    record.status = cancellation.isCancelled ? .cancelled : .failed
    record.error = error.localizedDescription
    record.finishedAt = Date()
    try save()
  }

  public func finish(_ result: some Encodable) throws {
    guard record.status == .running, !cancellation.isCancelled else {
      throw MisoError.invalid("Cannot finalize an inactive or cancelled operation")
    }
    record.result = try JSONDecoder().decode(JSONValue.self, from: JSON.encode(result))
    record.status = .complete
    record.finishedAt = Date()
    try save()
  }

  private func save() throws {
    try SafeFile.replace(JSON.encode(record), at: output.appendingPathComponent("journal.json"))
  }

  private static func validateName(_ name: String) throws {
    guard name.range(of: #"\A[a-z][a-z0-9-]{0,79}\z"#, options: .regularExpression) != nil else {
      throw MisoError.invalid("Invalid operation or command name")
    }
  }
}

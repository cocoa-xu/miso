import Darwin
import Foundation
import MisoSystem

public final class CancellationToken: @unchecked Sendable {
  let storage: OpaquePointer

  public init() throws {
    guard let token = miso_cancellation_create() else {
      throw MisoError.system("Allocate cancellation token", ENOMEM)
    }
    storage = token
  }

  deinit { miso_cancellation_destroy(storage) }
  public var isCancelled: Bool { miso_cancellation_requested(storage) }
  public func cancel() { miso_cancellation_request(storage) }
  public func check() throws {
    if isCancelled { throw CancellationError() }
  }
}

public struct NativeCommand: Sendable {
  public enum SystemTool: String, CaseIterable, Sendable {
    case diskImages = "/usr/bin/hdiutil"
    case disks = "/usr/sbin/diskutil"
    case checkSeal = "/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_checkseal"
    case packages = "/usr/sbin/pkgutil"
    case bom = "/usr/bin/lsbom"
    case copy = "/usr/bin/ditto"
    case manualIndex = "/usr/libexec/makewhatis"
    case mountAPFS = "/sbin/mount_apfs"
    case mount = "/sbin/mount"
    case unmount = "/sbin/umount"
    case codesign = "/usr/bin/codesign"
  }

  public let executable: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let timeout: TimeInterval
  public let input: URL?
  public let redactedArguments: Set<Int>
  private(set) var appleToolSHA256: String?

  static func restoreTool(
    _ url: URL, sha256: String, arguments: [String], timeout: TimeInterval = 3600
  ) throws -> Self {
    try SafeFile.validateSHA256(sha256)
    var command = try Self(url.path, arguments: arguments, timeout: timeout)
    command.appleToolSHA256 = sha256
    return command
  }

  public init(_ tool: SystemTool, arguments: [String] = [], timeout: TimeInterval = 300) throws {
    try self.init(tool.rawValue, arguments: arguments, timeout: timeout)
  }

  init(
    _ executable: String, arguments: [String] = [], timeout: TimeInterval = 300,
    environment: [String: String] = [:], input: URL? = nil, redactedArguments: Set<Int> = []
  ) throws {
    guard executable.hasPrefix("/"), !executable.contains("\0"),
      arguments.allSatisfy({ !$0.contains("\0") }), timeout.isFinite, timeout > 0,
      timeout <= 172_800,
      redactedArguments.allSatisfy({ arguments.indices.contains($0) }),
      environment.allSatisfy({
        !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0")
          && !$0.value.contains("\0")
      })
    else {
      throw MisoError.invalid("Invalid native command")
    }
    self.executable = URL(fileURLWithPath: executable)
    self.arguments = arguments
    self.timeout = timeout
    self.input = input
    self.redactedArguments = redactedArguments
    self.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
      .merging(environment) { _, value in value }
  }

  public var recordedArguments: [String] {
    [executable.path]
      + arguments.enumerated().map {
        redactedArguments.contains($0.offset) ? "<redacted>" : $0.element
      }
  }
}

public struct ProcessReceipt: Codable, Sendable {
  public let exitCode: Int32
  public let signal: Int32
  public let timedOut: Bool
  public let cancelled: Bool
  public let elapsedSeconds: Double
  public var succeeded: Bool { exitCode == 0 && signal == 0 && !timedOut && !cancelled }
}

public enum NativeProcess {
  public static func run(
    _ command: NativeCommand, stdout: FileHandle, stderr: FileHandle,
    cancellation: CancellationToken? = nil
  ) throws -> ProcessReceipt {
    if let expected = command.appleToolSHA256 {
      guard command.executable.path == command.executable.resolvingSymlinksInPath().path,
        try SafeFile.sha256(command.executable) == expected
      else { throw MisoError.invalid("Restore executable changed") }
      try AppleCode.validate(command.executable)
    }
    let input: FileHandle
    if let url = command.input {
      input = try SafeFile.openRegular(url)
    } else {
      let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
      guard fd >= 0 else { throw MisoError.system("Open null input", errno) }
      input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    defer { try? input.close() }
    let strings = [command.executable.path] + command.arguments
    let environment = command.environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
    var result = miso_process_result()
    let status = try withCStringArray(strings) { arguments in
      try withCStringArray(environment) { environment in
        command.executable.path.withCString { executable in
          miso_process_run(
            executable, arguments, environment, input.fileDescriptor,
            stdout.fileDescriptor, stderr.fileDescriptor, command.timeout, 2,
            cancellation?.storage, &result)
        }
      }
    }
    guard status == 0 else { throw MisoError.system("Launch native command", status) }
    return ProcessReceipt(
      exitCode: result.exit_code, signal: result.signal, timedOut: result.timed_out,
      cancelled: result.cancelled, elapsedSeconds: result.elapsed_seconds)
  }

  private static func withCStringArray<T>(
    _ values: [String], body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T
  ) throws -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in pointers { free(pointer) } }
    for value in values {
      guard let pointer = strdup(value) else {
        throw MisoError.system("Allocate process argument", ENOMEM)
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
  }
}

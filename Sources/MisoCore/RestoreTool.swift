import Darwin
import Foundation

struct RestoreTool {
  struct Receipt: Codable {
    let original: ImageBundle.FileRecord
    let executable: ImageBundle.FileRecord
    let signature: String
  }

  let executable: URL
  let receipt: Receipt

  static func prepare(_ name: String, inputs: PreparedInputs, journal: ExecutionJournal) throws
    -> Self
  {
    guard ["apfs_sealvolume", "fsck_apfs", "newfs_apfs"].contains(name),
      let record = inputs.receipt.tools[name]
    else { throw MisoError.invalid("Unknown restore tool") }
    return try prepare(
      source: inputs.file(name, cancellation: journal.cancellation), sha256: record.sha256,
      journal: journal)
  }

  static func prepare(source: URL, sha256: String, journal: ExecutionJournal) throws -> Self {
    try SafeFile.validateSHA256(sha256)
    try SafeFile.requireNoSymlinks(source)
    let original = try Artifacts.record(source, relativeTo: source.deletingLastPathComponent())
    guard original.sha256 == sha256 else { throw MisoError.invalid("Restore tool digest mismatch") }
    try AppleCode.validate(source)
    let name = "local-" + source.lastPathComponent
    let executable = journal.output.appendingPathComponent(name)
    try Artifacts.copy(
      source, to: executable, maximumBytes: 128 << 20, cancellation: journal.cancellation)
    guard try SafeFile.sha256(executable) == sha256 else {
      throw MisoError.invalid("Restore tool copy changed")
    }
    try AppleCode.validate(executable)
    guard chmod(executable.path, 0o700) == 0 else {
      throw MisoError.system("Set local restore tool permissions", errno)
    }
    try journal.run(
      "remove-signature-" + name,
      NativeCommand(.codesign, arguments: ["--remove-signature", executable.path]))
    try journal.run(
      "sign-" + name,
      NativeCommand(.codesign, arguments: ["--sign", "-", "--timestamp=none", executable.path]))
    try AppleCode.validateLocalTool(executable)
    guard try SafeFile.sha256(source) == sha256 else {
      throw MisoError.invalid("Original restore tool changed")
    }
    let receipt = Receipt(
      original: original, executable: try Artifacts.record(executable, relativeTo: journal.output),
      signature: "ad-hoc-without-entitlements")
    try journal.setMetadata("restoreTool-" + source.lastPathComponent, value: receipt)
    return Self(executable: executable, receipt: receipt)
  }

  func command(arguments: [String], timeout: TimeInterval = 3600) throws -> NativeCommand {
    try NativeCommand.localRestoreTool(
      executable, sha256: receipt.executable.sha256, arguments: arguments, timeout: timeout)
  }
}

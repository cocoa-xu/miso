import Foundation

struct PreparedInputs {
  let directory: URL
  let receipt: RestorePreparation.Receipt
  let journalRecord: ImageBundle.FileRecord

  init(_ directory: URL) throws {
    guard directory.path == directory.resolvingSymlinksInPath().path else {
      throw MisoError.invalid("Prepared input path must be canonical")
    }
    self.directory = directory
    let journalURL = directory.appendingPathComponent("journal.json")
    let journal = try JSON.read(ExecutionJournal.Record.self, from: journalURL)
    guard journal.schemaVersion == 1, journal.operation == "prepare-restore",
      journal.status == .complete,
      !journal.vmStarted, let result = journal.result
    else { throw MisoError.invalid("Preparation is not complete") }
    receipt = try JSONDecoder().decode(RestorePreparation.Receipt.self, from: JSON.encode(result))
    let manifest = try JSON.read(
      RestorePreparation.Receipt.self, from: directory.appendingPathComponent("prepared.json"))
    guard try JSON.encode(receipt) == JSON.encode(manifest),
      try RestoreProfile.select(receipt.profile.release) == receipt.profile,
      journal.metadata["ipswSHA256"] == .string(receipt.profile.ipswSHA256),
      let ecid = UInt64(receipt.ecid), ecid > 0
    else {
      throw MisoError.invalid("Prepared manifest, target profile or archive digest mismatch")
    }
    journalRecord = try Artifacts.record(journalURL, relativeTo: directory)
  }

  func file(_ name: String, cancellation: CancellationToken? = nil) throws -> URL {
    guard let record = receipt.derived[name] ?? receipt.tools[name] else {
      throw MisoError.invalid("Missing prepared artifact: \(name)")
    }
    return try Artifacts.resolve(record, under: directory, cancellation: cancellation)
  }

  func component(_ name: String, cancellation: CancellationToken? = nil) throws -> URL {
    let archiveManifest = try requireInput("BuildManifest.plist", cancellation: cancellation)
    let restore = try requireInput("Restore.plist", cancellation: cancellation)
    let inspection = try RestoreInspection.select(
      manifest: RestoreInspection.plist(SafeFile.read(archiveManifest, limit: 64 << 20)),
      restore: RestoreInspection.plist(SafeFile.read(restore, limit: 64 << 20)))
    guard inspection.profile == receipt.profile, let path = inspection.componentPaths[name] else {
      throw MisoError.invalid("Prepared component identity mismatch")
    }
    return try requireInput(path, cancellation: cancellation)
  }

  func requireInput(_ path: String, cancellation: CancellationToken? = nil) throws -> URL {
    guard let record = receipt.inputs[path] else {
      throw MisoError.invalid("Missing prepared input")
    }
    return try Artifacts.resolve(record, under: directory, cancellation: cancellation)
  }
}

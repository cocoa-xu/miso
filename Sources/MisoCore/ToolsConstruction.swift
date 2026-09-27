import Darwin
import Foundation

public enum ToolsConstruction {
  public struct Receipt: Codable, Sendable, ConstructedDiskReceipt {
    public let volumes: VolumeConstruction.Receipt
    public let sourceJournal: ImageBundle.FileRecord
    public let disk: ImageBundle.FileRecord
    let tools: CommandLineTools.Receipt
  }

  public static func run(
    prepared: URL, dataStage: URL, packages: URL, output: URL,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("CLT construction requires administrator privileges")
    }
    _ = try APFSPrivate.requireHost()
    let inputs = try PreparedInputs(prepared)
    _ = try CommandLineTools.validateInputs(
      packages: packages, profile: inputs.receipt.profile, cancellation: cancellation)
    let source = try ConstructedDisk<DataConstruction.Receipt>(
      directory: dataStage, operation: "populate-data", inputs: inputs, cancellation: cancellation)
    let journal = try ExecutionJournal(
      output: output, operation: "install-clt", cancellation: cancellation)
    return try journal.perform {
      let session = try source.clone(journal: journal)
      let volumes = source.receipt.volumes
      let tools = try session.withAttachment { session in
        let state = try ImageChecks.layout(session, volumes: volumes, journal: journal)
        guard let main = state[.main] else { throw MisoError.invalid("Missing main container") }
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "data",
          readOnly: false)
        let tools = try CommandLineTools.install(
          data: data, packages: packages, profile: volumes.profile, journal: journal)
        try Artifacts.requireSpace(8 << 30, at: data.root)
        return tools
      }
      try journal.setMetadata("tools", value: tools)
      try ImageChecks.filesystems(session, volumes: volumes, inputs: inputs, journal: journal)
      let result = Receipt(
        volumes: volumes, sourceJournal: source.journalRecord,
        disk: try Artifacts.record(session.image, relativeTo: journal.output), tools: tools)
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("tools.json"))
      return result
    }
  }
}

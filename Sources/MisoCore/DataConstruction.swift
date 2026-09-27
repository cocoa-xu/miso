import Darwin
import Foundation

public enum DataConstruction {
  public struct Receipt: Codable, Sendable {
    public let volumes: VolumeConstruction.Receipt
    public let sourceJournal: ImageBundle.FileRecord
    public let disk: ImageBundle.FileRecord
    let template: DataTemplate.Receipt
    let account: OfflineAccount.Receipt
  }

  public static func run(
    prepared: URL, volumeStage: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Data construction requires administrator privileges")
    }
    _ = try APFSPrivate.requireHost()
    let inputs = try PreparedInputs(prepared)
    let source = try ConstructedDisk<VolumeConstruction.Receipt>(
      directory: volumeStage, operation: "create-volumes", inputs: inputs,
      cancellation: cancellation)
    let volumes = source.receipt
    let configuration = try ImageConfiguration.read(
      Artifacts.resolve(inputs.receipt.configuration, under: prepared, cancellation: cancellation))
    let journal = try ExecutionJournal(
      output: output, operation: "populate-data", cancellation: cancellation)
    return try journal.perform {
      let session = try source.clone(journal: journal)
      let populated = try session.withAttachment { session in
        let state = try ImageChecks.layout(session, volumes: volumes, journal: journal)
        guard let main = state[.main] else { throw MisoError.invalid("Missing main container") }
        let system = try ImageMounts.mount(
          main.volume(role: "System"), session: session, journal: journal, name: "system",
          readOnly: true)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "data",
          readOnly: false)
        try journal.setMetadata("stage", value: "copy-data-template")
        let template = try DataTemplate.populate(
          system: system, data: data, profile: volumes.profile, cancellation: journal.cancellation)
        try journal.setMetadata("template", value: template)
        try journal.setMetadata("stage", value: "configure-account")
        let account = try OfflineAccount.apply(
          system: system, data: data, profile: volumes.profile,
          configuration: configuration, cancellation: journal.cancellation)
        try Artifacts.requireSpace(8 << 30, at: data.root)
        return (template, account)
      }
      try ImageChecks.filesystems(session, volumes: volumes, inputs: inputs, journal: journal)
      let result = Receipt(
        volumes: volumes, sourceJournal: source.journalRecord,
        disk: try Artifacts.record(session.image, relativeTo: journal.output),
        template: populated.0, account: populated.1)
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("data.json"))
      return result
    }
  }
}

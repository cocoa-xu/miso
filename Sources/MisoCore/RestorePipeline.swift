import Darwin
import Foundation

@MainActor
public enum RestorePipeline {
  public struct Receipt: Encodable, Sendable {
    public let profile: RestoreProfile
    public let bundle: String
    public let files: [ImageBundle.FileRecord]
    public let configuration: VirtualHardware.ValidationReceipt
  }

  public static func run(
    ipsw: URL, configuration: ImageConfiguration, packages: URL, output: URL,
    diskBytes: UInt64 = 40 << 30, keepDownloads: Bool = false,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Offline restore requires administrator privileges")
    }
    try configuration.validate()
    guard !configuration.installRosetta else {
      throw MisoError.unsupported("offline macOS Rosetta installation")
    }
    _ = try APFSPrivate.requireHost()
    _ = try GuestVolume(packages)
    let journal = try ExecutionJournal(
      output: output, operation: "restore-vanilla", cancellation: cancellation)
    let prepared = journal.output.appendingPathComponent("prepared")
    let system = journal.output.appendingPathComponent("system")
    let volumes = journal.output.appendingPathComponent("volumes")
    let data = journal.output.appendingPathComponent("data")
    let tools = journal.output.appendingPathComponent("tools")
    let material = journal.output.appendingPathComponent("policy-material")
    let boot = journal.output.appendingPathComponent("boot")
    let assembled = journal.output.appendingPathComponent("assembled")
    do {
      try journal.setMetadata("stage", value: "acquire-ipsw")
      let archive = try await RestoreArchive.acquire(
        ipsw, workspace: journal.output, cancellation: journal.cancellation)
      try journal.setMetadata("ipswSource", value: ipsw.absoluteString)
      try journal.setMetadata("ipswDownloaded", value: archive.downloaded)
      try journal.setMetadata("keepDownloads", value: keepDownloads)
      try journal.setMetadata("stage", value: "preflight-inputs")
      let inspection = try RestoreInspection.inspect(archive.url)
      try journal.setMetadata("target", value: inspection.profile.release)
      _ = try CommandLineTools.validateInputs(
        packages: packages, profile: inspection.profile, cancellation: journal.cancellation)
      try journal.setMetadata("stage", value: "prepare")
      let inputs = try await RestorePreparation.run(
        ipsw: archive.url, configuration: configuration, output: prepared,
        cancellation: journal.cancellation)
      let removed = try archive.removeDownload(keepDownloads: keepDownloads)
      try journal.setMetadata("downloadedIPSWRemoved", value: removed)
      try journal.setMetadata("target", value: inputs.profile.release)
      try journal.setMetadata("stage", value: "seal-system")
      _ = try SystemConstruction.run(
        prepared: prepared, output: system, diskBytes: diskBytes, cancellation: journal.cancellation
      )
      try journal.setMetadata("stage", value: "create-volumes")
      _ = try VolumeConstruction.run(
        prepared: prepared, systemStage: system, output: volumes, cancellation: journal.cancellation
      )
      try journal.setMetadata("stage", value: "populate-data")
      _ = try DataConstruction.run(
        prepared: prepared, volumeStage: volumes, output: data, cancellation: journal.cancellation)
      try journal.setMetadata("stage", value: "install-clt")
      _ = try ToolsConstruction.run(
        prepared: prepared, dataStage: data, packages: packages, output: tools,
        cancellation: journal.cancellation)
      try journal.setMetadata("stage", value: "prepare-policy-material")
      _ = try KernelCollection.prepare(
        prepared: prepared, output: material, cancellation: journal.cancellation)
      try journal.setMetadata("stage", value: "personalize-boot")
      _ = try await BootPersonalization.run(
        prepared: prepared, toolsStage: tools, materialStage: material, output: boot,
        cancellation: journal.cancellation)
      try journal.setMetadata("stage", value: "assemble-bundle")
      let assembly = try BundleAssembly.run(
        prepared: prepared, toolsStage: tools, bootStage: boot, output: assembled,
        cancellation: journal.cancellation)
      try journal.setMetadata("stage", value: "validate-configuration")
      let validation = try VirtualHardware.validateBundle(
        assembled.appendingPathComponent("bundle"), allowUnavailableHost: true)
      let result = Receipt(
        profile: inputs.profile, bundle: "assembled/bundle", files: assembly.files,
        configuration: validation)
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

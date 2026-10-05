import CryptoKit
import Darwin
import Foundation

@MainActor
public enum BundleAssembly {
  public struct Receipt: Codable, Sendable {
    public let profile: RestoreProfile
    public let sourceJournal: ImageBundle.FileRecord
    public let bootJournal: ImageBundle.FileRecord
    public let files: [ImageBundle.FileRecord]
    public let bundle: String
    public let runtimeVerified: Bool
    public let crossMacVerified: Bool
  }

  public static func run(
    prepared: URL, toolsStage: URL, bootStage: URL, output: URL,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Bundle assembly requires administrator privileges")
    }
    _ = try APFSPrivate.requireHost()
    let inputs = try PreparedInputs(prepared)
    let source = try ConstructedDisk<ToolsConstruction.Receipt>(
      directory: toolsStage, operation: "install-clt", inputs: inputs, cancellation: cancellation)
    let journalURL = bootStage.appendingPathComponent("journal.json")
    let bootJournal = try JSON.read(ExecutionJournal.Record.self, from: journalURL)
    guard bootJournal.operation == "personalize-boot", bootJournal.status == .complete,
      !bootJournal.vmStarted, let value = bootJournal.result
    else { throw MisoError.invalid("Completed boot personalization is required") }
    let boot = try JSONDecoder().decode(BootPersonalization.Receipt.self, from: JSON.encode(value))
    guard boot.profile == inputs.receipt.profile, boot.preparedJournal == inputs.journalRecord,
      boot.sourceJournal == source.journalRecord,
      boot.volumeGroup == source.receipt.volumes.volumeGroup
    else { throw MisoError.invalid("Boot personalization lineage mismatch") }
    let auxiliary = try Artifacts.resolve(
      boot.auxiliary, under: bootStage, cancellation: cancellation)
    let auxData = try SafeFile.read(auxiliary, limit: AuxiliaryStorage.size)
    try AuxiliaryStorage.verifyPanicLog(auxData)
    let bank = try NVRAM.decode(auxData.subdata(in: 0xA84000..<0xB04000))
    let main = source.receipt.volumes.layout.partitions[1]
    let selection = AuxiliaryStorage.BootSelection(
      partitionType: main.type, partitionIdentifier: main.identifier,
      systemIdentifier: boot.volumeGroup)
    guard bank.generation == 6, bank.variables["boot-volume"] == Data(selection.value.utf8),
      let nonces = bank.variables["boop-storage-nonces"], nonces.count == 112,
      BootPersonalization.hex384(nonces[16..<32]) == boot.lpnh
    else { throw MisoError.invalid("Auxiliary storage policy binding mismatch") }
    let journal = try ExecutionJournal(
      output: output, operation: "assemble-bundle", cancellation: cancellation)
    return try journal.perform {
      try Artifacts.requireSpace(12 << 30, at: journal.output)
      let bundle = journal.output.appendingPathComponent("bundle")
      try SafeFile.makeDirectory(bundle)
      let session = try source.clone(
        journal: journal, destination: bundle.appendingPathComponent("disk.img"))
      try Artifacts.copy(
        auxiliary, to: bundle.appendingPathComponent("aux.bin"),
        maximumBytes: UInt64(AuxiliaryStorage.size))
      let identity = boot.identity.filter {
        ["hardware-model.bin", "machine-identifier.bin"].contains(
          URL(fileURLWithPath: $0.path).lastPathComponent)
      }
      guard identity.count == 2,
        Set(identity.map { URL(fileURLWithPath: $0.path).lastPathComponent }).count == 2
      else { throw MisoError.invalid("Incomplete bundle identity") }
      for record in identity {
        let origin = try Artifacts.resolve(record, under: bootStage)
        try Artifacts.copy(
          origin, to: bundle.appendingPathComponent(origin.lastPathComponent), maximumBytes: 1 << 20
        )
      }
      try session.withAttachment { session in
        let mounts = try BootInstallation.mounts(
          session: session, volumes: source.receipt.volumes, journal: journal, readOnly: false)
        try BootInstallation.install(
          boot, source: bootStage.appendingPathComponent("tree"), mounts: mounts,
          cancellation: journal.cancellation)
        try BootInstallation.verify(boot, mounts: mounts, cancellation: journal.cancellation)
      }
      try ImageChecks.filesystems(
        session, volumes: source.receipt.volumes, inputs: inputs, journal: journal)
      let audit = try DiskImageSession(image: session.image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let mounts = try BootInstallation.mounts(
          session: session, volumes: source.receipt.volumes, journal: journal, readOnly: true)
        try BootInstallation.verify(boot, mounts: mounts, cancellation: journal.cancellation)
        let state = try ImageChecks.layout(
          session, volumes: source.receipt.volumes, journal: journal)
        guard let main = state[.main] else {
          throw MisoError.invalid("Missing final System container")
        }
        let volume = try main.volume(role: "System")
        _ = try ImageMounts.mount(
          volume, session: session, journal: journal, name: "final-system", readOnly: true)
        let info = try journal.plist(
          SystemConstruction.VolumeInfo.self, name: "final-system-info",
          command: NativeCommand(.disks, arguments: ["info", "-plist", volume.device]))
        let snapshots = try journal.plist(
          SystemConstruction.Snapshots.self, name: "final-snapshots",
          command: NativeCommand(
            .disks, arguments: ["apfs", "listSnapshots", volume.device, "-plist"]))
        _ = try SystemConstruction.verify(
          info: info, snapshots: snapshots, container: main.identifier, volume: volume.identifier,
          expectedName: inputs.receipt.snapshotName)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "final-data",
          readOnly: true)
        try Artifacts.requireSpace(8 << 30, at: data.root)
      }
      let configuration = try ImageConfiguration.read(
        Artifacts.resolve(
          inputs.receipt.configuration, under: prepared, cancellation: journal.cancellation))
      let optimization = try ImageOptimization.apply(
        bundle: bundle, username: configuration.username, journal: journal)
      let files = try ImageBundle.requiredFiles.sorted().map {
        try Artifacts.record(
          bundle.appendingPathComponent($0), relativeTo: bundle, cancellation: journal.cancellation)
      }
      let manifest: [String: Any] = [
        "schema_version": 1,
        "target": ["version": boot.profile.release.version, "build": boot.profile.release.build],
        "ecid": inputs.receipt.ecid, "volume_group_uuid": boot.volumeGroup.uuidString,
        "construction_vm_started": false, "runtime_verified": false, "cross_mac_verified": false,
        "install_rosetta": false, "minimum_cpus": 2, "minimum_memory_bytes": UInt64(4 << 30),
        "network_configuration": "supplied-by-launcher",
        "optimization": try JSONSerialization.jsonObject(with: JSON.encode(optimization)),
        "files": try JSONSerialization.jsonObject(with: JSON.encode(files)),
      ]
      try SafeFile.writeNew(
        JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
        to: bundle.appendingPathComponent("manifest.json"))
      let result = Receipt(
        profile: boot.profile, sourceJournal: source.journalRecord,
        bootJournal: try Artifacts.record(journalURL, relativeTo: bootStage), files: files,
        bundle: "bundle", runtimeVerified: false, crossMacVerified: false)
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("assembly.json"))
      return result
    }
  }
}

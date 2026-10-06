import Darwin
import Foundation
import Virtualization

@MainActor
public enum TartBundle {
  struct Configuration: Decodable {
    let version: Int
    let os: String
    let arch: String
    let diskFormat: String
    let hardwareModel: Data
    let ecid: Data
  }

  struct Metadata: Decodable {
    let target: MacOSRelease
    let constructionVMStarted: Bool
    let minimumCPUs: Int
    let minimumMemoryBytes: UInt64

    enum CodingKeys: String, CodingKey {
      case target
      case constructionVMStarted = "construction_vm_started"
      case minimumCPUs = "minimum_cpus"
      case minimumMemoryBytes = "minimum_memory_bytes"
    }
  }

  public struct Receipt: Encodable, Sendable {
    public let target: MacOSRelease
    public let sourceManifest: ImageBundle.FileRecord
    public let files: [ImageBundle.FileRecord]
    public let bundle = "vm"
    public let vmStarted = false
  }

  public struct ImportReceipt: Encodable, Sendable {
    public let target: MacOSRelease
    public let sourceManifest: ImageBundle.FileRecord
    public let files: [ImageBundle.FileRecord]
    public let bundle = "bundle"
    public let vmStarted = false
  }

  public static func importImage(
    source: URL, manifest manifestURL: URL, output: URL,
    diskBytes: UInt64? = nil, cancellation: CancellationToken? = nil
  ) throws -> ImportReceipt {
    _ = try GuestVolume(source)
    let bytes = try SafeFile.read(manifestURL, limit: 1 << 20)
    let metadata = try JSONDecoder().decode(Metadata.self, from: bytes)
    let manifest = try JSONDecoder().decode(ImageBundle.Manifest.self, from: bytes)
    try manifest.validate()
    _ = try RestoreProfile.select(metadata.target)
    guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      !metadata.constructionVMStarted, fields["runtime_verified"] as? Bool == false
    else {
      throw MisoError.invalid("Tart import requires the original unbooted MISO manifest")
    }
    let configuration = try JSON.read(
      Configuration.self, from: source.appendingPathComponent("config.json"), limit: 1 << 20)
    let records = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
    if let diskBytes {
      guard geteuid() == 0, let originalBytes = records["disk.img"]?.bytes,
        diskBytes > originalBytes, diskBytes <= 2 << 40, diskBytes % 4096 == 0
      else {
        throw MisoError.invalid(
          "Disk expansion requires administrator privileges and a larger aligned size")
      }
    }
    guard configuration.version == 1, configuration.os == "darwin",
      configuration.arch == "arm64", configuration.diskFormat == "raw",
      VZMacHardwareModel(dataRepresentation: configuration.hardwareModel) != nil,
      VZMacMachineIdentifier(dataRepresentation: configuration.ecid) != nil,
      SafeFile.sha256(configuration.hardwareModel) == records["hardware-model.bin"]?.sha256,
      SafeFile.sha256(configuration.ecid) == records["machine-identifier.bin"]?.sha256,
      records["aux.bin"]?.bytes == UInt64(AuxiliaryStorage.size)
    else { throw MisoError.invalid("Tart image identity differs from its MISO manifest") }
    let journal = try ExecutionJournal(
      output: output, operation: "import-tart", cancellation: cancellation)
    return try journal.perform {
      let bundle = output.appendingPathComponent("bundle")
      try SafeFile.makeDirectory(bundle)
      try SafeFile.writeNew(
        configuration.hardwareModel, to: bundle.appendingPathComponent("hardware-model.bin"))
      try SafeFile.writeNew(
        configuration.ecid, to: bundle.appendingPathComponent("machine-identifier.bin"))
      for (original, name) in [("disk.img", "disk.img"), ("nvram.bin", "aux.bin")] {
        try Artifacts.clone(
          source.appendingPathComponent(original), to: bundle.appendingPathComponent(name))
      }
      try SafeFile.writeNew(bytes, to: bundle.appendingPathComponent("manifest.json"))
      let verification = try ImageBundle.verify(bundle, cancellation: journal.cancellation)
      var files = verification.files
      if let diskBytes {
        let details = try DiskExpansion.run(
          image: bundle.appendingPathComponent("disk.img"), bytes: diskBytes, journal: journal)
        let disk = try Artifacts.record(
          bundle.appendingPathComponent("disk.img"), relativeTo: bundle,
          cancellation: journal.cancellation)
        files = files.map { $0.path == "disk.img" ? disk : $0 }
        var expanded = fields
        expanded["files"] = try JSONSerialization.jsonObject(with: JSON.encode(files))
        expanded["disk_expansion"] = try JSONSerialization.jsonObject(with: JSON.encode(details))
        try SafeFile.replace(
          JSONSerialization.data(withJSONObject: expanded, options: [.prettyPrinted, .sortedKeys]),
          at: bundle.appendingPathComponent("manifest.json"))
      }
      return ImportReceipt(
        target: metadata.target,
        sourceManifest: .init(
          path: manifestURL.lastPathComponent, bytes: UInt64(bytes.count),
          sha256: SafeFile.sha256(bytes)), files: files)
    }
  }

  public static func export(
    source: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    _ = try GuestVolume(source)
    let manifestURL = source.appendingPathComponent("manifest.json")
    let metadata = try JSON.read(Metadata.self, from: manifestURL, limit: 1 << 20)
    _ = try RestoreProfile.select(metadata.target)
    guard !metadata.constructionVMStarted, (2...64).contains(metadata.minimumCPUs),
      ((UInt64(4) << 30)...(UInt64(256) << 30)).contains(metadata.minimumMemoryBytes)
    else { throw MisoError.invalid("Invalid offline bundle hardware requirements") }
    let verification = try ImageBundle.verify(source, cancellation: cancellation)
    let records = Dictionary(uniqueKeysWithValues: verification.files.map { ($0.path, $0) })
    let model = try SafeFile.read(
      source.appendingPathComponent("hardware-model.bin"), limit: 1 << 20)
    let identifier = try SafeFile.read(
      source.appendingPathComponent("machine-identifier.bin"), limit: 1 << 20)
    guard SafeFile.sha256(model) == records["hardware-model.bin"]?.sha256,
      SafeFile.sha256(identifier) == records["machine-identifier.bin"]?.sha256,
      VZMacHardwareModel(dataRepresentation: model) != nil,
      VZMacMachineIdentifier(dataRepresentation: identifier) != nil,
      records["aux.bin"]?.bytes == UInt64(AuxiliaryStorage.size)
    else { throw MisoError.invalid("Invalid or changed bundle identity") }
    let journal = try ExecutionJournal(
      output: output, operation: "export-tart", cancellation: cancellation)
    return try journal.perform {
      let bundle = journal.output.appendingPathComponent("vm")
      try SafeFile.makeDirectory(bundle)
      try Artifacts.clone(
        source.appendingPathComponent("disk.img"), to: bundle.appendingPathComponent("disk.img"))
      try Artifacts.copy(
        source.appendingPathComponent("aux.bin"), to: bundle.appendingPathComponent("nvram.bin"),
        maximumBytes: UInt64(AuxiliaryStorage.size), cancellation: journal.cancellation)
      let configuration: [String: Any] = [
        "version": 1, "os": "darwin", "arch": "arm64", "diskFormat": "raw",
        "cpuCountMin": metadata.minimumCPUs, "cpuCount": max(4, metadata.minimumCPUs),
        "memorySizeMin": metadata.minimumMemoryBytes, "memorySize": metadata.minimumMemoryBytes,
        "hardwareModel": model.base64EncodedString(), "ecid": identifier.base64EncodedString(),
        "macAddress": VZMACAddress.randomLocallyAdministered().string,
        "display": ["width": 1024, "height": 768],
      ]
      try SafeFile.writeNew(
        JSONSerialization.data(
          withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys]),
        to: bundle.appendingPathComponent("config.json"))
      let files = try ["config.json", "disk.img", "nvram.bin"].map {
        try Artifacts.record(
          bundle.appendingPathComponent($0), relativeTo: bundle, cancellation: journal.cancellation)
      }
      for (name, original) in [("disk.img", "disk.img"), ("nvram.bin", "aux.bin")] {
        guard let file = files.first(where: { $0.path == name }), let expected = records[original],
          file.bytes == expected.bytes, file.sha256 == expected.sha256
        else { throw MisoError.invalid("Tart export differs from its source: \(name)") }
      }
      let receipt = Receipt(
        target: metadata.target,
        sourceManifest: try Artifacts.record(manifestURL, relativeTo: source), files: files)
      try SafeFile.writeNew(
        JSON.encode(receipt), to: journal.output.appendingPathComponent("export.json"))
      return receipt
    }
  }
}

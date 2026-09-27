import CoreFoundation
import Darwin
import Foundation

@MainActor
public enum RestorePreparation {
  public struct Receipt: Codable, Sendable {
    public let profile: RestoreProfile
    public let ecid: String
    public let snapshotName: String
    public let inputs: [String: ImageBundle.FileRecord]
    public let derived: [String: ImageBundle.FileRecord]
    public let tools: [String: ImageBundle.FileRecord]
    public let identity: [ImageBundle.FileRecord]
    public let configuration: ImageBundle.FileRecord
  }

  public static func run(
    ipsw: URL, configuration: ImageConfiguration, output: URL,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    try configuration.validate()
    guard geteuid() == 0 else {
      throw MisoError.invalid(
        "Restore preparation requires administrator privileges for its read-only restore-tools mount"
      )
    }
    guard !configuration.installRosetta else {
      throw MisoError.unsupported("offline Rosetta installation")
    }
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-restore", cancellation: cancellation)
    do {
      guard journal.record.host.architecture == "arm64" else {
        throw MisoError.unsupported("restore preparation requires Apple silicon")
      }
      let archive = try IPSWArchive(ipsw)
      var inspected = try RestoreInspection.inspect(archive)
      try journal.setMetadata("target", value: inspected.profile.release)
      try journal.setMetadata("stage", value: "verify-ipsw")
      try archive.verifySHA256(inspected.profile.ipswSHA256, cancellation: journal.cancellation)
      inspected.ipswSHA256 = archive.verifiedArchiveSHA256
      let paths = try inputPaths(inspected)
      var extractionBytes: UInt64 = 0
      for path in paths {
        let (sum, overflow) = extractionBytes.addingReportingOverflow(try archive.memberSize(path))
        guard !overflow, sum <= 128 << 30 else {
          throw MisoError.invalid("Restore input size exceeds limit")
        }
        extractionBytes = sum
      }
      try Artifacts.requireSpace(extractionBytes + (40 << 30), at: journal.output)
      try journal.setMetadata("ipswSHA256", value: inspected.profile.ipswSHA256)
      let configurationURL = journal.output.appendingPathComponent("configuration.json")
      try SafeFile.writeNew(JSON.encode(configuration), to: configurationURL)
      let inputs = journal.output.appendingPathComponent("inputs")
      let decoded = journal.output.appendingPathComponent("decoded")
      let tools = journal.output.appendingPathComponent("tools")
      for directory in [inputs, decoded, tools] { try SafeFile.makeDirectory(directory) }
      try journal.setMetadata("stage", value: "extract-inputs")
      var extracted: [String: ImageBundle.FileRecord] = [:]
      for path in paths {
        let destination = try Artifacts.makeParents(for: path, under: inputs)
        let record = try archive.extract(path, to: destination, cancellation: journal.cancellation)
        extracted[path] = .init(path: "inputs/" + path, bytes: record.bytes, sha256: record.sha256)
      }
      try journal.setMetadata("inputs", value: extracted)
      try journal.setMetadata("stage", value: "create-identity")
      let identity = try await VirtualHardware.createIdentity(
        ipsw: ipsw, output: journal.output.appendingPathComponent("identity"), inspected: inspected)
      let machine = try RestoreInspection.plist(
        SafeFile.read(
          journal.output.appendingPathComponent("identity/machine-identifier.bin"), limit: 1 << 20))
      guard let identifier = machine["ECID"] as? NSNumber,
        CFGetTypeID(identifier) != CFBooleanGetTypeID(),
        !CFNumberIsFloatType(unsafeBitCast(identifier, to: CFNumber.self)),
        identifier.uint64Value != 0
      else {
        throw MisoError.invalid("Invalid machine ECID")
      }
      let ecid = identifier.stringValue
      var derived: [String: ImageBundle.FileRecord] = [:]
      for name in ["OS", "BaseSystem", "Cryptex1,SystemOS"] {
        try journal.cancellation.check()
        try journal.setMetadata("stage", value: "decrypt-" + name)
        let path = try component(name, inspected: inspected)
        guard path.hasSuffix(".aea") else {
          throw MisoError.unsupported("encrypted restore component format")
        }
        let source = inputs.appendingPathComponent(path)
        let destination = decoded.appendingPathComponent(
          name.replacingOccurrences(of: ",", with: "-") + ".dmg")
        let key = try await AEA.decryptionKey(source, cancellation: journal.cancellation)
        let receipt = try EncryptedArchive.decrypt(
          source: source, output: destination, key: key, cancellation: journal.cancellation)
        derived[name] = .init(
          path: "decoded/" + destination.lastPathComponent, bytes: receipt.bytes,
          sha256: receipt.sha256)
        try journal.setMetadata("derived", value: derived)
      }
      try journal.setMetadata("stage", value: "decode-metadata")
      for (name, filename) in [
        ("RestoreRamDisk", "ramdisk.dmg"), ("Ap,SystemVolumeCanonicalMetadata", "canonical.pbze"),
        ("SystemVolume", "system-auth.bin"),
      ] {
        let record = try Image4.unwrap(
          source: inputs.appendingPathComponent(component(name, inspected: inspected)),
          output: decoded.appendingPathComponent(filename), cancellation: journal.cancellation)
        derived[name] = .init(
          path: "decoded/" + filename, bytes: record.bytes, sha256: record.sha256)
      }
      _ = try PBZE.decode(
        source: decoded.appendingPathComponent("canonical.pbze"),
        output: decoded.appendingPathComponent("canonical.aar"))
      let canonical = journal.output.appendingPathComponent("canonical")
      try CanonicalMetadata.extract(
        decoded.appendingPathComponent("canonical.aar"), to: canonical,
        cancellation: journal.cancellation)
      let remap = try CanonicalMetadata.timestampRemap(
        canonical.appendingPathComponent("mtree.txt"))
      let remapURL = canonical.appendingPathComponent("timestamp-remap.plist")
      try SafeFile.writeNew(
        PropertyListSerialization.data(fromPropertyList: remap, format: .xml, options: 0),
        to: remapURL)
      let ticket = try SafeFile.read(
        inputs.appendingPathComponent(ticketPath(inspected.profile)), limit: 8 << 20)
      let payload = try SafeFile.read(
        inputs.appendingPathComponent(component("SystemVolume", inspected: inspected)),
        limit: 1 << 20)
      let rootURL = canonical.appendingPathComponent("system-root.img4")
      try SafeFile.writeNew(Image4.stitch(payload: payload, ticket: ticket), to: rootURL)
      derived["timestamp-remap"] = try Artifacts.record(remapURL, relativeTo: journal.output)
      derived["signed-system-root"] = try Artifacts.record(rootURL, relativeTo: journal.output)
      for name in ["digest.db", "mtree.txt"] {
        derived[name] = try Artifacts.record(
          canonical.appendingPathComponent(name), relativeTo: journal.output)
      }
      try journal.setMetadata("stage", value: "extract-apfs-tools")
      let ramdisk = try DiskImageSession(
        image: decoded.appendingPathComponent("ramdisk.dmg"), readOnly: true, journal: journal)
      let mount = journal.output.appendingPathComponent("restore-mount")
      let toolRecords = try ramdisk.withAttachment(requireGPT: false, mountPoint: mount) { _ in
        var result: [String: ImageBundle.FileRecord] = [:]
        for name in ["apfs_sealvolume", "fsck_apfs", "newfs_apfs"] {
          let source = mount.appendingPathComponent(
            "System/Library/Filesystems/apfs.fs/Contents/Resources/" + name)
          let destination = tools.appendingPathComponent(name)
          try Artifacts.copy(
            source, to: destination, maximumBytes: 128 << 20, cancellation: journal.cancellation)
          try AppleCode.validate(destination)
          guard chmod(destination.path, 0o700) == 0 else {
            throw MisoError.system("Set restore tool permissions", errno)
          }
          result[name] = try Artifacts.record(destination, relativeTo: journal.output)
        }
        return result
      }
      let result = Receipt(
        profile: inspected.profile, ecid: ecid,
        snapshotName: try Image4.snapshotName(
          authBlob: SafeFile.read(decoded.appendingPathComponent("system-auth.bin"), limit: 4096)),
        inputs: extracted, derived: derived, tools: toolRecords,
        identity: identity.files.map {
          .init(path: "identity/" + $0.path, bytes: $0.bytes, sha256: $0.sha256)
        },
        configuration: try Artifacts.record(configurationURL, relativeTo: journal.output))
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("prepared.json"))
      try journal.finish(result)
      return result
    } catch {
      if journal.record.status == .running { try journal.fail(error) }
      throw error
    }
  }

  static func inputPaths(_ inspected: RestoreInspection) throws -> [String] {
    var paths = Set(inspected.componentPaths.values)
    paths.formUnion([
      "BuildManifest.plist", "Restore.plist", "SystemVersion.plist", "RestoreVersion.plist",
      "usr/standalone/bootcaches.plist",
    ])
    paths.insert(ticketPath(inspected.profile))
    paths.insert(ticketPath(inspected.profile, cryptex: true))
    return try paths.map(SafeFile.relativePath).sorted()
  }

  static func ticketPath(_ profile: RestoreProfile, cryptex: Bool = false) -> String {
    "Firmware/Manifests/restore/" + (cryptex ? "cryptex1/" : "") + "macOS Customer/apticket."
      + profile.deviceClass + ".im4m"
  }

  static func component(_ name: String, inspected: RestoreInspection) throws -> String {
    guard let path = inspected.componentPaths[name] else {
      throw MisoError.invalid("Missing restore component: \(name)")
    }
    return path
  }
}

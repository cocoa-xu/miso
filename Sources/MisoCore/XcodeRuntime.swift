import CryptoKit
import Darwin
import Foundation

public enum XcodeRuntime {
  public struct Requirement: Codable, Equatable, Sendable {
    public let platform: XcodeConfiguration.Platform
    public let version: String
    public let build: String

    public init(platform: XcodeConfiguration.Platform, version: String, build: String) {
      self.platform = platform
      self.version = version
      self.build = build
    }

    func validate(_ configuration: XcodeConfiguration) throws {
      try configuration.validate()
      _ = try StableVersion(version)
      var buildValidation = configuration
      buildValidation.build = build
      try buildValidation.validate()
      guard configuration.platforms.contains(platform), configuration.build == "27A266a",
        try StableVersion(configuration.version) == StableVersion("27.0"),
        try StableVersion(version) == StableVersion("27.0")
      else { throw MisoError.unsupported("Xcode simulator runtime requirement") }
    }
  }

  public struct Receipt: Codable, Sendable {
    public let schemaVersion: Int
    public let requirement: Requirement
    public let catalog: ImageBundle.FileRecord
    public let archive: ImageBundle.FileRecord
    public let files: [ImageBundle.FileRecord]
    public let diskImage: String
    public let decryptedSHA256: String
    public let runtimePath: String
    public let runtimeIdentifier: String
    public let hostInstalled: Bool
    public let xcodeImageComplete: Bool
    public let runtimeVerified: Bool
    public let vmStarted: Bool
  }

  static func select(_ payload: Data, requirement: Requirement) throws -> AppleAssetCatalog.Asset {
    let asset = try AppleAssetCatalog.select(
      payload, assetType: requirement.platform.assetType, build: requirement.build)
    guard let catalog = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let assets = catalog["Assets"] as? [[String: Any]], assets.count == 1,
      assets[0]["Architectures"] as? [String] == ["arm64"],
      assets[0]["SimulatorVersion"] as? String == requirement.version
    else { throw MisoError.invalid("Simulator asset architecture or version differs") }
    return asset
  }

  public static func prepare(
    requirement: Requirement, configuration: XcodeConfiguration = .init(), catalog: URL? = nil,
    archive: URL? = nil, output: URL, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    try requirement.validate(configuration)
    guard archive == nil || catalog != nil else {
      throw MisoError.invalid("Simulator archive replay requires a signed catalog")
    }
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-runtime", cancellation: cancellation)
    do {
      try journal.setMetadata("requirement", value: requirement)
      if let catalog {
        let signed = try SafeFile.read(catalog, limit: 8 << 20)
        let payload = try AppleAssetCatalog.verify(signed)
        _ = try select(payload, requirement: requirement)
        try SafeFile.writeNew(signed, to: output.appendingPathComponent("catalog.jwt"))
        try SafeFile.writeNew(payload, to: output.appendingPathComponent("catalog.json"))
      } else {
        _ = try await AppleAssetCatalog.fetch(
          assetType: requirement.platform.assetType, build: requirement.build, journal: journal)
      }
      let asset = try select(
        SafeFile.read(output.appendingPathComponent("catalog.json"), limit: 8 << 20),
        requirement: requirement)
      try journal.setMetadata("asset", value: asset)
      try Artifacts.requireSpace(
        asset.downloadBytes * 2 + asset.expandedBytes + (2 << 30), at: output)
      let encrypted = output.appendingPathComponent("asset.aar")
      if let archive {
        try Artifacts.copy(
          archive, to: encrypted, maximumBytes: asset.downloadBytes,
          cancellation: journal.cancellation)
      } else {
        try await HTTPFile.appleAsset(
          asset.url, to: encrypted, maximumBytes: asset.downloadBytes,
          cancellation: journal.cancellation)
      }
      return try journal.perform {
        let original = try Artifacts.record(encrypted, relativeTo: output)
        guard original.bytes == asset.downloadBytes, original.sha256 == asset.sha256,
          let key = Data(base64Encoded: asset.decryptionKey)
        else { throw MisoError.invalid("Simulator archive size or digest mismatch") }
        let decoded = output.appendingPathComponent("decrypted.aar")
        let decrypted = try EncryptedArchive.decrypt(
          source: encrypted, output: decoded, key: SymmetricKey(data: key),
          maximumOutputBytes: asset.decryptionLimit, cancellation: journal.cancellation)
        let expanded = output.appendingPathComponent("expanded")
        try journal.run(
          "extract-simulator-asset",
          NativeCommand(
            .appleArchive,
            arguments: ["patch", "-i", decoded.path, "-dst", expanded.path, "-t", "2"],
            timeout: 1800))
        let disk = try inspect(
          expanded, requirement: requirement, cancellation: journal.cancellation)
        var files: [ImageBundle.FileRecord] = []
        var bytes: UInt64 = 0
        try FileMetadata.walk(expanded) { path, info in
          try journal.cancellation.check()
          guard [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT), files.count < 64 else {
            throw MisoError.invalid("Unexpected simulator asset entry")
          }
          if info.st_mode & S_IFMT == S_IFREG {
            let record = try Artifacts.record(
              expanded.appendingPathComponent(path), relativeTo: output)
            guard record.bytes <= asset.expandedBytes - bytes else {
              throw MisoError.invalid("Simulator payload exceeds catalog size")
            }
            bytes += record.bytes
            files.append(record)
          }
        }
        guard files.count >= 6 else { throw MisoError.invalid("Incomplete simulator asset") }
        let session = try DiskImageSession(image: disk, readOnly: true, journal: journal)
        let mount = output.appendingPathComponent("runtime-mount")
        let runtime = try session.withAttachment(requireGPT: false, mountPoint: mount) { _ in
          try inspectRuntime(GuestVolume(mount), requirement: requirement)
        }
        guard try Artifacts.record(encrypted, relativeTo: output) == original,
          try select(
            AppleAssetCatalog.verify(
              SafeFile.read(output.appendingPathComponent("catalog.jwt"), limit: 8 << 20)),
            requirement: requirement) == asset
        else { throw MisoError.invalid("Simulator preparation inputs changed") }
        let result = Receipt(
          schemaVersion: 1, requirement: requirement,
          catalog: try Artifacts.record(
            output.appendingPathComponent("catalog.jwt"), relativeTo: output), archive: original,
          files: files.sorted { $0.path < $1.path },
          diskImage: try Artifacts.record(disk, relativeTo: output).path,
          decryptedSHA256: decrypted.sha256, runtimePath: runtime.0, runtimeIdentifier: runtime.1,
          hostInstalled: false, xcodeImageComplete: false, runtimeVerified: false, vmStarted: false)
        try SafeFile.writeNew(
          JSON.encode(result), to: output.appendingPathComponent("runtime.json"))
        try FileManager.default.removeItem(at: decoded)
        return result
      }
    } catch {
      if journal.record.status == .running { try journal.fail(error) }
      throw error
    }
  }

  static func inspect(_ root: URL, requirement: Requirement, cancellation: CancellationToken?)
    throws -> URL
  {
    let volume = try GuestVolume(root)
    let info = try volume.plist("Info.plist")
    guard info["CFBundleIdentifier"] as? String == requirement.platform.assetType,
      let properties = info["MobileAssetProperties"] as? [String: Any],
      properties["Build"] as? String == requirement.build,
      properties["Architectures"] as? [String] == ["arm64"],
      properties["SimulatorVersion"] as? String == requirement.version
    else { throw MisoError.invalid("Simulator asset identity differs") }
    let restore = try GuestVolume(volume.directory("AssetData/Restore").url)
    let manifest = try restore.plist("BuildManifest.plist")
    guard manifest["ProductBuildVersion"] as? String == requirement.build,
      let identities = manifest["BuildIdentities"] as? [[String: Any]]
    else { throw MisoError.invalid("Unexpected simulator restore manifest") }
    let matches = identities.filter {
      guard let info = $0["Info"] as? [String: Any] else { return false }
      return info["DeviceClass"] as? String == "macoscryptexap"
        && info["Variant"] as? String == "Arm64Only Customer Simulator Runtime"
    }
    guard matches.count == 1, let identity = matches.first,
      let components = identity["Manifest"] as? [String: [String: Any]],
      let image = components["Cryptex1,GenericDmg"],
      let imageInfo = image["Info"] as? [String: Any],
      let path = imageInfo["Path"] as? String, path.hasSuffix(".dmg"), !path.contains("/"),
      imageInfo["HashMethod"] as? String == "sha2-384", let digest = image["Digest"] as? Data,
      digest.count == 48
    else { throw MisoError.invalid("Unexpected simulator disk identity") }
    let disk = try restore.path(path)
    guard try BootTree.hash384(disk, cancellation: cancellation) == digest else {
      throw MisoError.invalid("Simulator disk image digest mismatch")
    }
    return disk
  }

  static func inspectRuntime(_ volume: GuestVolume, requirement: Requirement) throws -> (
    String, String
  ) {
    let prefix = "Library/Developer/CoreSimulator/Profiles/Runtimes"
    let names = try FileManager.default.contentsOfDirectory(
      atPath: volume.directory(prefix).url.path)
    guard names.count == 1, let name = names.first, name.hasSuffix(".simruntime") else {
      throw MisoError.invalid("Expected one simulator runtime")
    }
    let path = prefix + "/" + name
    let runtime = try GuestVolume(volume.directory(path).url)
    return (path, try inspectRuntimeBundle(runtime, requirement: requirement))
  }

  static func inspectRuntimeBundle(_ runtime: GuestVolume, requirement: Requirement) throws
    -> String
  {
    let info = try runtime.plist("Contents/Info.plist")
    let profile = try runtime.plist("Contents/Resources/profile.plist")
    let version = try runtime.plist(
      "Contents/Resources/RuntimeRoot/System/Library/CoreServices/SystemVersion.plist")
    guard let identifier = info["CFBundleIdentifier"] as? String,
      identifier.hasPrefix("com.apple.CoreSimulator.SimRuntime."),
      profile["platformIdentifier"] as? String == requirement.platform.simulatorIdentifier,
      profile["defaultVersionString"] as? String == requirement.version,
      (profile["supportedArchs"] as? [String])?.contains("arm64") == true,
      version["ProductVersion"] as? String == requirement.version,
      version["ProductBuildVersion"] as? String == requirement.build
    else { throw MisoError.invalid("Mounted simulator runtime identity differs") }
    return identifier
  }
}

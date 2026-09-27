import CryptoKit
import Darwin
import Foundation

public enum XcodeMetal {
  public struct Receipt: Codable {
    let schemaVersion: Int
    let build: String
    let catalog: ImageBundle.FileRecord
    let archive: ImageBundle.FileRecord
    let files: [ImageBundle.FileRecord]
    let diskImage: String
    let toolchainIdentifier: String
    let metalSHA256: String
    let decryptedSHA256: String
    let hostInstalled: Bool
    let xcodeImageComplete: Bool
    let runtimeVerified: Bool
    let vmStarted: Bool
  }

  public static func prepare(
    configuration: XcodeConfiguration = .init(), catalog: URL? = nil, archive: URL? = nil,
    output: URL, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    try configuration.validate()
    guard configuration.components.contains(.metalToolchain), (catalog == nil) == (archive == nil)
    else { throw MisoError.invalid("Metal replay requires both a signed catalog and its archive") }
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-metal", cancellation: cancellation)
    do {
      try journal.setMetadata("configuration", value: configuration)
      try Artifacts.requireSpace(4 << 30, at: output)
      let asset: AppleAssetCatalog.Asset
      if let catalog {
        let signed = try SafeFile.read(catalog, limit: 8 << 20)
        let payload = try AppleAssetCatalog.verify(signed)
        asset = try AppleAssetCatalog.select(
          payload, assetType: "com.apple.MobileAsset.MetalToolchain", build: configuration.build)
        try SafeFile.writeNew(signed, to: output.appendingPathComponent("catalog.jwt"))
        try SafeFile.writeNew(payload, to: output.appendingPathComponent("catalog.json"))
      } else {
        asset = try await AppleAssetCatalog.fetchMetal(build: configuration.build, journal: journal)
      }
      try journal.setMetadata("asset", value: asset)
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
        let archiveRecord = try Artifacts.record(encrypted, relativeTo: output)
        guard archiveRecord.bytes == asset.downloadBytes, archiveRecord.sha256 == asset.sha256,
          let key = Data(base64Encoded: asset.decryptionKey)
        else { throw MisoError.invalid("Metal archive size or digest mismatch") }
        let decoded = output.appendingPathComponent("decrypted.aar")
        let decrypted = try EncryptedArchive.decrypt(
          source: encrypted, output: decoded, key: SymmetricKey(data: key),
          maximumOutputBytes: asset.decryptionLimit, cancellation: journal.cancellation)
        let expanded = output.appendingPathComponent("expanded")
        try journal.run(
          "extract-metal-asset",
          NativeCommand(
            .appleArchive,
            arguments: ["patch", "-i", decoded.path, "-dst", expanded.path, "-t", "2"],
            timeout: 900))
        let disk = try inspect(
          expanded, build: configuration.build, cancellation: journal.cancellation)
        var files: [ImageBundle.FileRecord] = []
        var bytes: UInt64 = 0
        try FileMetadata.walk(expanded) { path, info in
          try journal.cancellation.check()
          guard [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT), files.count < 64 else {
            throw MisoError.invalid("Unexpected Metal asset entry")
          }
          if info.st_mode & S_IFMT == S_IFREG {
            let record = try Artifacts.record(
              expanded.appendingPathComponent(path), relativeTo: output)
            guard record.bytes <= asset.expandedBytes - bytes else {
              throw MisoError.invalid("Metal payload exceeds its catalog size")
            }
            bytes += record.bytes
            files.append(record)
          }
        }
        guard files.count >= 6 else { throw MisoError.invalid("Incomplete Metal asset payload") }
        let session = try DiskImageSession(image: disk, readOnly: true, journal: journal)
        let mount = output.appendingPathComponent("metal-mount")
        let toolchain = try session.withAttachment(requireGPT: false, mountPoint: mount) { _ in
          let root = try GuestVolume(mount.appendingPathComponent("Metal.xctoolchain"))
          let info = try root.plist("ToolchainInfo.plist")
          guard let identifier = info["Identifier"] as? String,
            identifier.hasPrefix("com.apple.dt.toolchain.Metal.")
          else { throw MisoError.invalid("Unexpected Metal toolchain identity") }
          let executable = try root.path("usr/bin/metal")
          try AppleCode.validate(executable)
          return (identifier, try SafeFile.sha256(executable))
        }
        guard try SafeFile.sha256(encrypted) == archiveRecord.sha256 else {
          throw MisoError.invalid("Metal archive changed during preparation")
        }
        let result = Receipt(
          schemaVersion: 1, build: configuration.build,
          catalog: try Artifacts.record(
            output.appendingPathComponent("catalog.jwt"), relativeTo: output),
          archive: archiveRecord, files: files.sorted { $0.path < $1.path },
          diskImage: String(disk.path.dropFirst(output.path.count + 1)),
          toolchainIdentifier: toolchain.0, metalSHA256: toolchain.1,
          decryptedSHA256: decrypted.sha256, hostInstalled: false,
          xcodeImageComplete: false, runtimeVerified: false, vmStarted: false)
        try SafeFile.writeNew(JSON.encode(result), to: output.appendingPathComponent("metal.json"))
        try FileManager.default.removeItem(at: decoded)
        return result
      }
    } catch {
      if journal.record.status == .running { try journal.fail(error) }
      throw error
    }
  }

  static func inspect(_ root: URL, build: String, cancellation: CancellationToken? = nil) throws
    -> URL
  {
    let volume = try GuestVolume(root)
    let info = try volume.plist("Info.plist")
    guard info["CFBundleIdentifier"] as? String == "com.apple.MobileAsset.MetalToolchain",
      let properties = info["MobileAssetProperties"] as? [String: Any],
      properties["Build"] as? String == build
    else { throw MisoError.invalid("Metal asset identity differs from the selected Xcode") }
    let restore = try volume.directory("AssetData/Restore").url
    let manifest = try GuestVolume(restore).plist("BuildManifest.plist")
    guard manifest["ProductBuildVersion"] as? String == build,
      let identities = manifest["BuildIdentities"] as? [[String: Any]]
    else { throw MisoError.invalid("Unsupported Metal restore manifest") }
    let matches = identities.filter {
      guard let info = $0["Info"] as? [String: Any] else { return false }
      return info["DeviceClass"] as? String == "macoscryptexap"
        && info["Variant"] as? String == "Customer Metal Toolchain"
        && info["BuildNumber"] as? String == build
    }
    guard matches.count == 1, let identity = matches.first,
      let components = identity["Manifest"] as? [String: [String: Any]],
      let image = components["Cryptex1,GenericDmg"],
      let imageInfo = image["Info"] as? [String: Any],
      let path = imageInfo["Path"] as? String, path.hasSuffix(".dmg"), !path.contains("/"),
      imageInfo["HashMethod"] as? String == "sha2-384", let digest = image["Digest"] as? Data,
      digest.count == 48
    else { throw MisoError.invalid("Unsupported Metal restore manifest") }
    let disk = try GuestVolume(restore).path(path)
    guard try BootTree.hash384(disk, cancellation: cancellation) == digest else {
      throw MisoError.invalid("Metal disk image digest mismatch")
    }
    return disk
  }
}

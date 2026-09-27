import CoreFoundation
import Foundation

public struct RestoreInspection: Encodable, Sendable {
  public let profile: RestoreProfile
  public let identityIndex: Int
  public let componentPaths: [String: String]
  public let launchRequirements: LaunchRequirements
  public var metadataSHA256: [String: String] = [:]
  public var ipswSHA256: String?
  public let vmStarted = false
  public let payloadsAuthenticated = false
  public let preflightOnly = true

  public struct LaunchRequirements: Encodable, Sendable {
    public let minimumCPUCount: Int
    public let minimumMemoryMB: Int
    public let minimumHostOS: String
  }

  public static func inspect(_ url: URL, verifyDigest: Bool = false) throws -> Self {
    let archive = try IPSWArchive(url)
    var report = try inspect(archive)
    if verifyDigest {
      try archive.verifySHA256(report.profile.ipswSHA256)
      report.ipswSHA256 = report.profile.ipswSHA256
    }
    return report
  }

  static func inspect(_ archive: IPSWArchive) throws -> Self {
    let manifest = try archive.read("BuildManifest.plist")
    let restore = try archive.read("Restore.plist")
    var report = try select(manifest: plist(manifest), restore: plist(restore))
    for path in report.componentPaths.values { try archive.requireComponent(path) }
    report.metadataSHA256 = [
      "BuildManifest.plist": SafeFile.sha256(manifest), "Restore.plist": SafeFile.sha256(restore),
    ]
    report.ipswSHA256 = archive.verifiedArchiveSHA256
    return report
  }

  static func plist(_ data: Data) throws -> [String: Any] {
    guard
      let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any]
    else {
      throw MisoError.invalid("Expected a property-list dictionary")
    }
    return value
  }

  static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self))
    else { return nil }
    return Int(exactly: number.int64Value)
  }

  static func select(manifest: [String: Any], restore: [String: Any]) throws -> Self {
    func release(_ metadata: [String: Any]) throws -> MacOSRelease {
      guard let version = metadata["ProductVersion"] as? String,
        let build = metadata["ProductBuildVersion"] as? String
      else {
        throw MisoError.invalid("Missing macOS version metadata")
      }
      return MacOSRelease(version: version, build: build)
    }
    let profile = try RestoreProfile.select(release(manifest))
    guard try release(restore) == profile.release, integer(manifest["ManifestVersion"]) == 0 else {
      throw MisoError.invalid("BuildManifest and Restore metadata disagree")
    }
    for metadata in [manifest, restore] {
      guard (metadata["SupportedProductTypes"] as? [String])?.contains(profile.productType) == true
      else {
        throw MisoError.invalid("IPSW does not support the selected virtual hardware")
      }
    }
    guard let identities = manifest["BuildIdentities"] as? [[String: Any]] else {
      throw MisoError.invalid("Missing build identities")
    }
    let matches = identities.enumerated().filter {
      let info = $0.element["Info"] as? [String: Any]
      return info?["DeviceClass"] as? String == profile.deviceClass
        && info?["Variant"] as? String == profile.restoreVariant
    }
    guard matches.count == 1, let match = matches.first,
      let info = match.element["Info"] as? [String: Any]
    else {
      throw MisoError.invalid("Expected exactly one matching erase-install identity")
    }
    let identity = match.element
    guard identity["Ap,ProductType"] as? String == profile.productType,
      identity["ProductMarketingVersion"] as? String == profile.release.version,
      info["BuildNumber"] as? String == profile.release.build,
      info["RestoreBehavior"] as? String == "Erase",
      info["ContentEncoding"] as? String == profile.contentEncoding
    else {
      throw MisoError.invalid("Restore identity product, build or encoding mismatch")
    }
    for (key, expected) in [
      ("ApChipID", profile.chipID), ("ApBoardID", profile.boardID),
      ("ApSecurityDomain", profile.securityDomain),
    ] {
      guard let value = identity[key] as? String,
        (value.hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)) == expected
      else {
        throw MisoError.invalid("Restore identity hardware mismatch: \(key)")
      }
    }
    let devices = (restore["DeviceMap"] as? [[String: Any]] ?? []).filter {
      $0["BoardConfig"] as? String == profile.deviceClass
    }
    guard devices.count == 1, let device = devices.first,
      integer(device["CPID"]) == profile.chipID, integer(device["BDID"]) == profile.boardID,
      integer(device["SDOM"]) == profile.securityDomain
    else { throw MisoError.invalid("Restore device map mismatch") }
    guard let components = identity["Manifest"] as? [String: [String: Any]] else {
      throw MisoError.invalid("Missing component manifest")
    }
    var paths: [String: String] = [:]
    for name in profile.requiredComponents {
      guard let component = components[name]?["Info"] as? [String: Any],
        let path = component["Path"] as? String
      else {
        throw MisoError.invalid("Missing component path: \(name)")
      }
      paths[name] = try SafeFile.relativePath(path)
    }
    for (name, value) in components {
      guard let info = value["Info"] as? [String: Any], let path = info["Path"] as? String else {
        throw MisoError.invalid("Missing component path: \(name)")
      }
      paths[name] = try SafeFile.relativePath(path)
    }
    guard let cpus = integer(info["VirtualMachineMinCPUCount"]), cpus > 0,
      let memory = integer(info["VirtualMachineMinMemorySizeMB"]), memory > 0,
      let host = info["VirtualMachineMinHostOS"] as? String, !host.isEmpty
    else {
      throw MisoError.invalid("Missing virtual machine launch requirements")
    }
    return Self(
      profile: profile, identityIndex: match.offset, componentPaths: paths,
      launchRequirements: .init(minimumCPUCount: cpus, minimumMemoryMB: memory, minimumHostOS: host)
    )
  }
}

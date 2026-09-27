import Foundation

public struct MacOSVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(_ value: String) throws {
    guard
      value.range(of: #"\A[1-9][0-9]*(\.(0|[1-9][0-9]*)){1,2}\z"#, options: .regularExpression)
        != nil
    else {
      throw MisoError.invalid("Expected a numeric macOS major.minor[.patch] version")
    }
    let fields = value.split(separator: ".").compactMap { Int($0) }
    guard fields.count == value.split(separator: ".").count else {
      throw MisoError.invalid("macOS version component is too large")
    }
    major = fields[0]
    minor = fields[1]
    patch = fields.count == 3 ? fields[2] : 0
  }

  public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  public static func requireUpgrade(from source: String, to target: String) throws {
    let old = try Self(source)
    let new = try Self(target)
    guard old.major == new.major, old < new else {
      throw MisoError.unsupported(
        "only strictly newer releases within one macOS major version can be upgraded")
    }
  }
}

public struct MacOSRelease: Codable, Hashable, Sendable {
  public let version: String
  public let build: String

  public init(version: String, build: String) {
    self.version = version
    self.build = build
  }
}

public struct RestoreProfile: Codable, Equatable, Sendable {
  public enum Family: String, Codable, Sendable { case sequoia, tahoe, goldenGate }

  public let release: MacOSRelease
  public let family: Family
  public let ipswSHA256: String
  public let commandLineTools: CommandLineTools

  public struct CommandLineTools: Codable, Equatable, Sendable {
    public let product: String
    public let version: String
    public let sdk: String
  }

  public var productType: String { "VirtualMac2,1" }
  public var deviceClass: String { "vma2macosap" }
  public var chipID: Int { 0xFE00 }
  public var boardID: Int { 0x20 }
  public var securityDomain: Int { 1 }
  public var restoreVariant: String { "Customer Erase Install (IPSW)" }
  public var contentEncoding: String { "aea" }
  public var deferredFirmlinks: [String] { family == .tahoe ? ["/pkg"] : [] }
  public var containsLinuxTranslation: Bool { family == .goldenGate }

  public var requiredComponents: [String] {
    [
      "OS", "SystemVolume", "StaticTrustCache", "Ap,SystemVolumeCanonicalMetadata",
      "BaseSystem", "BaseSystemVolume", "Ap,BaseSystemTrustCache",
      "Cryptex1,AppOS", "Cryptex1,AppVolume", "Cryptex1,AppTrustCache",
      "Cryptex1,SystemOS", "Cryptex1,SystemVolume", "Cryptex1,SystemTrustCache",
      "LLB", "iBoot", "DeviceTree", "KernelCache", "AppleLogo", "RestoreRamDisk",
      "RestoreTrustCache",
    ]
  }

  public var setupCompletedKeys: [String] {
    let common = [
      "DidSeeCloudSetup", "DidSeePrivacy", "DidSeeSiriSetup", "DidSeeTouchIDSetup",
      "DidSeeAppearanceSetup", "DidSeeScreenTime", "DidSeeAccessibility",
      "DidSeeiCloudLoginForStorageServices", "DidSeeSyncSetup",
    ]
    return family == .sequoia
      ? common
      : common + [
        "DidSeeSyncSetup2", "DidSeeAppStore", "DidSeeApplePaySetup", "DidSeeActivationLock",
        "DidSeeTermsOfAddress", "DidSeeLockdownMode",
      ]
  }

  public var setupVersionKeys: [String] {
    var keys = ["LastSeenCloudProductVersion", "LastSeenDiagnosticsProductVersion"]
    if family != .sequoia {
      keys += [
        "LastSeenSiriProductVersion", "LastSeenIntelligenceProductVersion",
        "LastSeenAgeRangeSelectionProductVersion", "LastSeenSyncProductVersion",
        "LastSeeniCloudStorageServicesProductVersion",
      ]
      keys.append(
        family == .tahoe
          ? "DidSeeNewFeaturesProductVersion" : "LastSeenGlassTintUpsellProductVersion")
    }
    return keys
  }

  public static let supported: [Self] = [
    Self(
      release: .init(version: "15.6.1", build: "24G90"), family: .sequoia,
      ipswSHA256: "3d87686b691ac765eb6a6b3082b2334e2af9710096a00432dd519af89ff2ea78",
      commandLineTools: .init(
        product: "082-41241", version: "16.4.0.0.1.1747106510", sdk: "MacOSX15.5.sdk")),
    Self(
      release: .init(version: "26.6.2", build: "25G83"), family: .tahoe,
      ipswSHA256: "885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95",
      commandLineTools: .init(
        product: "140-17812", version: "26.6.0.0.1781586589", sdk: "MacOSX26.5.sdk")),
    Self(
      release: .init(version: "27.0", build: "26A428"), family: .goldenGate,
      ipswSHA256: "2a5d3c695d501022b7fad9adaffcf2627bcb867d993fb5662dcd41bac99a2836",
      commandLineTools: .init(
        product: "082-83364", version: "27.0.0.0.1788430756", sdk: "MacOSX27.0.sdk")),
    Self(
      release: .init(version: "27.0.1", build: "26A434"), family: .goldenGate,
      ipswSHA256: "2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1",
      commandLineTools: .init(
        product: "082-83364", version: "27.0.0.0.1788430756", sdk: "MacOSX27.0.sdk")),
  ]

  public static func select(_ release: MacOSRelease) throws -> Self {
    guard let profile = supported.first(where: { $0.release == release }) else {
      throw MisoError.unsupported("restore target \(release.version)/\(release.build)")
    }
    return profile
  }
}

public struct UpgradeProfile: Codable, Equatable, Sendable {
  public let source: MacOSRelease
  public let target: MacOSRelease

  public static let supported: [Self] =
    [
      ("15.7.7", "24G720"), ("15.7.8", "24G824"), ("15.7.9", "24G830"), ("15.8", "24H23"),
    ].map {
      Self(
        source: .init(version: "15.6.1", build: "24G90"), target: .init(version: $0.0, build: $0.1))
    }
    + [
      Self(
        source: .init(version: "26.6.2", build: "25G83"),
        target: .init(version: "26.7", build: "25G229"))
    ]

  public static func select(source: MacOSRelease, target: MacOSRelease) throws -> Self {
    try MacOSVersion.requireUpgrade(from: source.version, to: target.version)
    guard let profile = supported.first(where: { $0.source == source && $0.target == target })
    else {
      throw MisoError.unsupported(
        "upgrade pair \(source.version)/\(source.build) -> \(target.version)/\(target.build)")
    }
    return profile
  }
}

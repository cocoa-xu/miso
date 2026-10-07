import Foundation

public enum XcodeCompletion {
  public struct DeveloperDisk: Encodable {
    public let platform: String
    public let archive: ImageBundle.FileRecord
    public let path: String
    public let entries: Int
    public let logicalBytes: UInt64
    public let contentSHA256: String
  }

  public struct Details: Encodable {
    public let configuration: XcodeConfiguration
    public let application: XcodeArchive.Application
    public let developerDisks: [DeveloperDisk]
    let trimming: IntelTrimming.Receipt?
    public let removedSDKs: [String]
    public let firstLaunchRuntimeVerified = false
  }

  public struct Receipt: Encodable {
    public let image: BaseStageReceipt<Details>
    public let bundle: String
    public let xcodeImageComplete = true
    public let runtimeVerified = false
    public let vmStarted = false
  }

  @MainActor
  public static func run(
    source: URL, output: URL, configuration: XcodeConfiguration = .init(),
    username: String = "admin",
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    try configuration.validate()
    try requireStages(
      SafeFile.read(source.appendingPathComponent("manifest.json"), limit: 1 << 20),
      configuration: configuration, finalized: false)
    let journal = try ExecutionJournal(
      output: output, operation: "complete-xcode-image", cancellation: cancellation)
    return try journal.perform {
      let image = try BaseImageStage.run(
        source: source, output: output.appendingPathComponent("image"),
        operation: "xcode-finalize", layer: .xcode, cancellation: journal.cancellation,
        optimizationUsername: username, xcodeApplication: configuration.applicationPath,
        optimizationProfile: configuration.buildProfile
      ) { bundle, target, stage in
        let session = try DiskImageSession(
          image: bundle.appendingPathComponent("disk.img"), readOnly: false, journal: stage)
        return try session.withAttachment { attached in
          let main = try BaseImageStage.mainContainer(attached)
          let data = try ImageMounts.mount(
            main.volume(role: "Data"), session: attached, journal: stage,
            name: "xcode-completion", readOnly: false)
          let app = try data.directory(configuration.applicationPath).url
          let application = try XcodeArchive.inspect(
            app, target: target, configuration: configuration)
          try AppleCode.validate(app)
          try stage.run(
            "verify-final-xcode",
            NativeCommand(
              .codesign, arguments: ["--verify", "--deep", "--strict", app.path], timeout: 900))
          try XcodeMetalInstallation.finalizeRegistration(configuration: configuration, data: data)
          try validateSelection(data, configuration: configuration)
          let disks = try installDeveloperDisks(
            data, application: app, configuration: configuration, journal: stage)
          let removed = try BuildProgress.run("Remove excluded Xcode SDKs") {
            try removeExcludedSDKs(data, configuration: configuration)
          }
          let trimming: IntelTrimming.Receipt?
          if configuration.profile?.trimIntel == true {
            trimming = try BuildProgress.run("Trim Intel architectures, preserving ARM signatures")
            {
              try IntelTrimming.run(
                data: data,
                roots: [
                  configuration.applicationPath, "opt/homebrew", "Users/\(username)/flutter",
                  "Users/\(username)/android-sdk", "Users/\(username)/.local/share/mise",
                ], cancellation: stage.cancellation)
            }
          } else {
            trimming = nil
          }
          return Details(
            configuration: configuration, application: application, developerDisks: disks,
            trimming: trimming, removedSDKs: removed)
        }
      }
      let bundle = output.appendingPathComponent("image/bundle")
      let hardware = try VirtualHardware.validateBundle(bundle, allowUnavailableHost: true)
      try journal.setMetadata("virtualHardware", value: hardware)
      let manifestURL = bundle.appendingPathComponent("manifest.json")
      let original = try SafeFile.read(manifestURL, limit: 1 << 20)
      try requireStages(original, configuration: configuration, finalized: true)
      guard var manifest = try JSONSerialization.jsonObject(with: original) as? [String: Any]
      else { throw MisoError.invalid("Invalid Xcode completion manifest") }
      manifest["xcode_complete"] = true
      manifest["xcode_configuration"] = try JSONSerialization.jsonObject(
        with: JSON.encode(configuration))
      try SafeFile.replace(
        JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
        at: manifestURL)
      return Receipt(image: image, bundle: "image/bundle")
    }
  }

  static func removeExcludedSDKs(_ data: GuestVolume, configuration: XcodeConfiguration) throws
    -> [String]
  {
    var removed: [String] = []
    for platform in XcodeConfiguration.Platform.allCases
    where !configuration.platforms.contains(platform) {
      for name in platform.sdkNames.keys.sorted() {
        let path =
          configuration.applicationPath
          + "/Contents/Developer/Platforms/\(name).platform/Developer/SDKs"
        guard try data.contains(path) else { continue }
        let directory = try data.directory(path).url
        try FileManager.default.removeItem(at: directory)
        removed.append(path)
      }
    }
    return removed
  }

  static func requiredStages(_ configuration: XcodeConfiguration) -> Set<String> {
    var stages: Set<String> = [
      "xcode-application", "xcode-packages", "xcode-bottles", "xcode-gems", "xcode-casks",
      "xcode-simulator-tools", "xcode-tuist", "xcode-android", "xcode-flutter",
    ]
    if configuration.components.contains(.metalToolchain) { stages.insert("xcode-metal") }
    for platform in configuration.platforms {
      stages.insert("xcode-runtime-" + platform.rawValue.lowercased())
    }
    return stages
  }

  static func requireStages(
    _ data: Data, configuration: XcodeConfiguration, finalized: Bool
  ) throws {
    var expected = requiredStages(configuration)
    if finalized { expected.insert("xcode-finalize") }
    guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      manifest["base_complete"] as? Bool == true,
      manifest["construction_vm_started"] as? Bool == false,
      manifest["runtime_verified"] as? Bool == false,
      manifest["xcode_complete"] as? Bool == false,
      let stages = manifest["xcode_stages"] as? [String],
      stages.count == expected.count, Set(stages) == expected
    else { throw MisoError.invalid("Incomplete or previously booted Xcode image") }
  }

  static func validateSelection(_ data: GuestVolume, configuration: XcodeConfiguration) throws {
    try XcodeApplication.requireSelection(
      "/" + configuration.applicationPath + "/Contents/Developer", data: data)
    let license = try data.plist("Library/Preferences/com.apple.dt.Xcode.plist")
    guard license["IDELastGMLicenseAgreedTo"] as? String == "EA2002",
      license["IDEXcodeVersionForAgreedToGMLicense"] as? String == configuration.version
    else { throw MisoError.invalid("Final Xcode license differs") }
    for policy in try XcodePackages.Policy.standard(configuration) {
      let receipt = try data.plist(
        "Library/Apple/System/Library/Receipts/" + policy.identifier + ".plist")
      guard receipt["PackageIdentifier"] as? String == policy.identifier,
        receipt["PackageVersion"] as? String == policy.version
      else { throw MisoError.invalid("Final first-launch package receipt differs") }
    }
  }

  static func validateDeveloperDisk(
    _ volume: GuestVolume, platform: String, configuration: XcodeConfiguration
  ) throws {
    let info = try volume.plist("version.plist")
    guard info["Platform"] as? String == platform,
      info["ProductBuildVersion"] as? String == configuration.build,
      info["Variant"] as? String == "Public",
      let version = info["BuildVersion"] as? String, UInt32(version) != nil
    else { throw MisoError.invalid("Developer disk identity differs") }
    _ = try volume.plist("Restore/BuildManifest.plist")
    _ = try volume.plist("Restore/Restore.plist")
  }

  static func installDeveloperDisks(
    _ data: GuestVolume, application: URL, configuration: XcodeConfiguration,
    journal: ExecutionJournal
  ) throws -> [DeveloperDisk] {
    let package = try GuestVolume(application).path(
      "Contents/Resources/Packages/XcodeSystemResources.pkg")
    let expanded = journal.output.appendingPathComponent("system-resources")
    try journal.run(
      "expand-developer-disks",
      NativeCommand(
        .packages, arguments: ["--expand-full", package.path, expanded.path], timeout: 300))
    let tree = try GuestVolume(expanded)
    let policy = try XcodePackages.Policy.standard(configuration).last!
    try policy.validateInfo(SafeFile.read(tree.path("PackageInfo"), limit: 2 << 20))
    let candidates = "Library/Developer/CoreDevice/CandidateDDIs/"
    var results: [DeveloperDisk] = []
    for platform in ["iOS", "watchOS", "tvOS", "xrOS"] {
      let archive = try data.path(candidates + platform + "_DDI.dmg")
      let record = try Artifacts.record(archive, relativeTo: data.root)
      guard record.sha256 == (try SafeFile.sha256(tree.path("Payload/" + record.path))) else {
        throw MisoError.invalid("Installed developer disk differs from its signed package")
      }
      let session = try DiskImageSession(image: archive, readOnly: true, journal: journal)
      let mount = journal.output.appendingPathComponent("ddi-" + platform)
      let installed = "Library/Developer/DeveloperDiskImages/" + platform + "_DDI"
      let payload = try session.withAttachment(requireGPT: false, mountPoint: mount) { _ in
        let volume = try GuestVolume(mount)
        try validateDeveloperDisk(volume, platform: platform, configuration: configuration)
        let audit = try XcodeComponentPayload.copy(
          mount, to: data, path: installed, journal: journal)
        try validateDeveloperDisk(
          GuestVolume(data.directory(installed).url), platform: platform,
          configuration: configuration)
        return audit
      }
      results.append(
        DeveloperDisk(
          platform: platform, archive: record, path: installed, entries: payload.entries,
          logicalBytes: payload.logicalBytes, contentSHA256: payload.contentSHA256))
    }
    return results
  }
}

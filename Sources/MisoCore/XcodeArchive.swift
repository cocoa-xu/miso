import Darwin
import Foundation

public enum XcodeArchive {
  public struct SDK: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let path: String
  }

  public struct Application: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let minimumMacOS: String
    public let sdks: [SDK]
  }

  public struct Receipt: Codable, Sendable {
    public let schemaVersion: Int
    public let target: MacOSRelease
    public let configuration: XcodeConfiguration
    public let archive: ImageBundle.FileRecord
    public let application: Application
    public let payload: String
    public let xcodeImageComplete: Bool
    public let runtimeVerified: Bool
    public let vmStarted: Bool
  }

  public static func prepare(
    archive: URL, sha256: String, target: MacOSRelease,
    configuration: XcodeConfiguration = .init(), output: URL,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    try configuration.validate()
    _ = try RestoreProfile.select(target)
    try SafeFile.validateSHA256(sha256)
    let record = try Artifacts.record(archive, relativeTo: archive.deletingLastPathComponent())
    guard archive.pathExtension == "xip", record.sha256 == sha256, record.bytes > 0 else {
      throw MisoError.invalid("Xcode archive digest or format mismatch")
    }
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-archive", cancellation: cancellation)
    return try journal.perform {
      try expand(
        archive: archive, record: record, target: target, configuration: configuration,
        output: output, journal: journal)
    }
  }

  public static func prepare(
    baseURL: String, target: MacOSRelease, configuration: XcodeConfiguration = .init(),
    output: URL, keepDownloads: Bool = false, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    try configuration.validate()
    _ = try RestoreProfile.select(target)
    _ = try XcodeDownload.source(baseURL: baseURL, filename: "Xcode_validation.xip")
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-archive", cancellation: cancellation)
    do {
      try Artifacts.requireSpace(32 << 30, at: output)
      let archive = try await XcodeDownload.acquire(
        baseURL: baseURL, configuration: configuration, workspace: output,
        cancellation: cancellation)
      let input = try SafeFile.openRegular(archive)
      defer { try? input.close() }
      var identity = stat()
      guard fstat(input.fileDescriptor, &identity) == 0 else {
        throw MisoError.system("Inspect downloaded Xcode archive", errno)
      }
      let record = try Artifacts.record(
        archive, relativeTo: archive.deletingLastPathComponent(), cancellation: cancellation)
      let receipt = try expand(
        archive: archive, record: record, target: target, configuration: configuration,
        output: output, journal: journal)
      if !keepDownloads {
        var current = stat()
        guard lstat(archive.path, &current) == 0,
          current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
          current.st_mode & S_IFMT == S_IFREG
        else {
          throw MisoError.invalid("Downloaded Xcode archive was replaced; refusing to remove it")
        }
        try FileManager.default.removeItem(at: archive)
      }
      try journal.setMetadata("downloadRetained", value: keepDownloads)
      try journal.finish(receipt)
      return receipt
    } catch {
      if journal.record.status == .running { try journal.fail(error) }
      throw error
    }
  }

  private static func expand(
    archive: URL, record: ImageBundle.FileRecord, target: MacOSRelease,
    configuration: XcodeConfiguration, output: URL, journal: ExecutionJournal
  ) throws -> Receipt {
    try journal.setMetadata("target", value: target)
    try journal.setMetadata("configuration", value: configuration)
    try journal.setMetadata("archive", value: record)
    try Artifacts.requireSpace(24 << 30, at: output)
    let expanded = output.appendingPathComponent("expanded")
    try SafeFile.makeDirectory(expanded)
    try journal.run(
      "expand-apple-xip",
      NativeCommand(
        .xip, arguments: ["--expand", archive.path], timeout: 3600,
        workingDirectory: expanded))
    guard try FileManager.default.contentsOfDirectory(atPath: expanded.path) == ["Xcode.app"]
    else { throw MisoError.invalid("Unexpected Xcode archive contents") }
    let app = expanded.appendingPathComponent("Xcode.app")
    try AppleCode.validate(app)
    try journal.run(
      "verify-xcode-signature",
      NativeCommand(
        .codesign, arguments: ["--verify", "--deep", "--strict", app.path], timeout: 900))
    let application = try inspect(app, target: target, configuration: configuration)
    guard try Artifacts.record(archive, relativeTo: archive.deletingLastPathComponent()) == record
    else { throw MisoError.invalid("Xcode archive changed during preparation") }
    let receipt = Receipt(
      schemaVersion: 1, target: target, configuration: configuration, archive: record,
      application: application, payload: "expanded/Xcode.app", xcodeImageComplete: false,
      runtimeVerified: false, vmStarted: false)
    try SafeFile.writeNew(JSON.encode(receipt), to: output.appendingPathComponent("archive.json"))
    return receipt
  }

  static func inspect(
    _ app: URL, target: MacOSRelease, configuration: XcodeConfiguration
  ) throws -> Application {
    try configuration.validate()
    _ = try RestoreProfile.select(target)
    let volume = try GuestVolume(app)
    let info = try volume.plist("Contents/Info.plist")
    let metadata = try volume.plist("Contents/version.plist")
    guard info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
      let version = info["CFBundleShortVersionString"] as? String,
      let recordedVersion = metadata["CFBundleShortVersionString"] as? String,
      let build = metadata["ProductBuildVersion"] as? String,
      let minimum = info["LSMinimumSystemVersion"] as? String,
      try StableVersion(version) == StableVersion(configuration.version),
      try StableVersion(recordedVersion) == StableVersion(version), build == configuration.build,
      try StableVersion(target.version) >= StableVersion(minimum)
    else { throw MisoError.invalid("Xcode identity or target macOS compatibility mismatch") }
    let required = configuration.platforms.reduce(into: ["MacOSX": "macosx"]) {
      $0.merge($1.sdkNames) { current, _ in current }
    }
    let sdks = try required.sorted(by: { $0.key < $1.key }).map { platform, name in
      let relative =
        "Contents/Developer/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk"
      let sdkPath = try volume.path(relative, allowLeafLink: true)
      guard let resolved = realpath(sdkPath.path, nil) else {
        throw MisoError.system("Resolve Xcode SDK", errno)
      }
      defer { free(resolved) }
      let path = URL(fileURLWithPath: String(cString: resolved))
      guard path.path.hasPrefix(app.path + "/") else {
        throw MisoError.invalid("Xcode SDK escapes its application")
      }
      let sdk = try GuestVolume(path).plist("SDKSettings.plist")
      guard let sdkVersion = sdk["Version"] as? String,
        sdk["CanonicalName"] as? String == name + sdkVersion
      else { throw MisoError.invalid("Unexpected Xcode SDK identity: \(name)") }
      _ = try StableVersion(sdkVersion)
      return SDK(name: name, version: sdkVersion, path: relative)
    }
    return Application(version: version, build: build, minimumMacOS: minimum, sdks: sdks)
  }
}

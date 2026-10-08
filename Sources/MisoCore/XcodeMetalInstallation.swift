import Darwin
import Foundation

public enum XcodeMetalInstallation {
  public struct Details: Encodable {
    public let configuration: XcodeConfiguration
    public let appleToolchainIdentifier: String
    public let toolchainIdentifier: String
    public let payloadPath: String
    public let registrationPath: String
    public let entries: Int
    public let assetIdentifier: String
    public let xcodeImageComplete = false
  }

  public struct Receipt: Encodable {
    public let input: XcodeMetal.Receipt
    public let image: BaseStageReceipt<Details>
    public let temporaryInputsRemoved: Bool
    public let vmStarted = false
  }

  public static func install(
    source: URL, prepared: URL, configuration: XcodeConfiguration = .init(),
    username: String = "admin",
    output: URL, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Offline Metal installation requires administrator privileges")
    }
    try configuration.validate()
    guard configuration.components.contains(.metalToolchain) else {
      throw MisoError.invalid("Metal is not configured for this image")
    }
    let original = try GuestVolume(prepared)
    let journal = try ExecutionJournal(
      output: output, operation: "install-xcode-metal", cancellation: cancellation)
    do {
      let inputs = output.appendingPathComponent("inputs")
      let authenticated = try await XcodeMetal.prepare(
        configuration: configuration, index: original.path("index.plist"),
        catalog: original.path("catalog.jwt"),
        archive: original.path("asset.aar"), output: inputs, cancellation: journal.cancellation)
      let image = try BaseImageStage.run(
        source: source, output: output.appendingPathComponent("image"), operation: "xcode-metal",
        layer: .xcode, cancellation: journal.cancellation
      ) { bundle, target, stage in
        let session = try DiskImageSession(
          image: bundle.appendingPathComponent("disk.img"), readOnly: false, journal: stage)
        return try session.withAttachment { attached in
          let main = try BaseImageStage.mainContainer(attached)
          let data = try ImageMounts.mount(
            main.volume(role: "Data"), session: attached, journal: stage,
            name: "metal-data", readOnly: false)
          let account = try BaseImageStage.Account(username, data: data)
          let app = try data.directory(configuration.applicationPath).url
          _ = try XcodeArchive.inspect(app, target: target, configuration: configuration)
          try AppleCode.validate(app)
          let result = try copy(
            authenticated, configuration: configuration, inputs: inputs,
            data: data, account: account, journal: stage)
          try AppleCode.validate(app)
          return result
        }
      }
      let disk = try GuestVolume(inputs).path(authenticated.diskImage)
      try DiskImageSession(image: disk, readOnly: true, journal: journal).requireDetached()
      for file in [disk, inputs.appendingPathComponent("asset.aar")] {
        guard try FileMetadata.inspect(file).st_mode & S_IFMT == S_IFREG else {
          throw MisoError.invalid("Unexpected temporary Metal input")
        }
        try FileManager.default.removeItem(at: file)
      }
      let result = Receipt(input: authenticated, image: image, temporaryInputsRemoved: true)
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  static func copy(
    _ input: XcodeMetal.Receipt, configuration: XcodeConfiguration, inputs: URL,
    data: GuestVolume, account: BaseImageStage.Account, journal: ExecutionJournal
  ) throws -> Details {
    let prepared = try GuestVolume(inputs)
    let catalog = try MetalAssetRegistration.catalog(
      SafeFile.read(prepared.path("catalog.json"), limit: 8 << 20), build: input.build)
    guard try !data.contains(catalog.assetPath),
      try !data.contains(MetalAssetRegistration.catalogPath)
    else { throw MisoError.invalid("Metal MobileAsset registration already exists") }
    try Artifacts.requireSpace(input.files.reduce(0) { $0 + $1.bytes }, at: data.root)
    try BuildProgress.run("Install Apple Metal MobileAsset") {
      for file in input.files {
        try journal.cancellation.check()
        guard file.path.hasPrefix("expanded/") else {
          throw MisoError.invalid("Metal file is outside its authenticated asset")
        }
        let relative = try SafeFile.relativePath(String(file.path.dropFirst("expanded/".count)))
        let source = try prepared.path(file.path)
        guard try FileMetadata.inspect(source).st_size == file.bytes else {
          throw MisoError.invalid("Prepared Metal asset size changed: \(relative)")
        }
        let destination = try data.path(catalog.assetPath + "/" + relative, createParents: true)
        try Artifacts.copy(
          source, to: destination, maximumBytes: file.bytes, cancellation: journal.cancellation)
        guard chmod(destination.path, 0o644) == 0 else {
          throw MisoError.system("Set Metal asset permissions", errno)
        }
      }
      try data.write(
        MetalAssetRegistration.catalogPath,
        data: PropertyListSerialization.data(
          fromPropertyList: catalog.properties, format: .xml, options: 0))
      try XcodeComponentIndex.install(
        SafeFile.read(prepared.path("index.plist"), limit: 8 << 20),
        configuration: configuration, build: input.build, data: data, account: account)
      try finalizeRegistration(configuration: configuration, data: data)
      try removeLegacyRegistration(configuration: configuration, data: data, account: account)
    }
    return Details(
      configuration: configuration, appleToolchainIdentifier: input.toolchainIdentifier,
      toolchainIdentifier: input.toolchainIdentifier, payloadPath: catalog.assetPath,
      registrationPath: MetalAssetRegistration.catalogPath, entries: input.files.count,
      assetIdentifier: catalog.identifier)
  }

  static func finalizeRegistration(configuration: XcodeConfiguration, data: GuestVolume) throws {
    guard configuration.components.contains(.metalToolchain) else { return }
    let catalog = try data.plist(MetalAssetRegistration.catalogPath)
    guard catalog["AssetType"] as? String == MetalAssetRegistration.type,
      let assets = catalog["Assets"] as? [[String: Any]], assets.count == 1,
      let attributes = assets.first, let build = attributes["Build"] as? String,
      attributes["AssetType"] as? String == MetalAssetRegistration.type
    else { throw MisoError.invalid("Invalid installed Metal MobileAsset catalog") }
    let identifier = try MetalAssetRegistration.identifier(attributes)
    let path = MetalAssetRegistration.directory + "/" + identifier + ".asset"
    _ = try XcodeMetal.diskImage(data.directory(path).url, build: build)
  }

  static func removeLegacyRegistration(
    configuration: XcodeConfiguration, data: GuestVolume, account: BaseImageStage.Account
  ) throws {
    try configuration.validate()
    let identifier = "moe.uwucocoa.miso.metal." + configuration.build
    let payload = "Library/Developer/MISO/Metal/\(configuration.build)"
    let registration = "Library/Developer/Toolchains/MISO-Metal-\(configuration.build).xctoolchain"
    if try data.contains(registration) {
      let info = try data.plist(registration + "/Info.plist")
      let link = try data.path(registration + "/usr", allowLeafLink: true)
      guard info["CFBundleIdentifier"] as? String == identifier,
        info["CompatibilityVersion"] as? Int == 2,
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
          == "/" + payload + "/Metal.xctoolchain/usr"
      else { throw MisoError.invalid("Refusing to remove an unrecognized Metal registration") }
      try FileManager.default.removeItem(at: data.directory(registration).url)
      if try data.contains(payload) {
        try FileManager.default.removeItem(at: data.directory(payload).url)
      }
    }
    let home = "Users/" + account.username
    for name in [".zshenv", ".zprofile"] {
      let path = home + "/" + name
      guard try data.contains(path) else { continue }
      let url = try data.path(path)
      let previous = try SafeFile.read(url, limit: 1 << 20)
      let cleaned = try removingLegacySelection(previous, configuration: configuration)
      if cleaned != previous {
        try data.write(
          path, data: cleaned, uid: account.uid, gid: account.gid,
          mode: FileMetadata.inspect(url).st_mode & 0o777)
      }
    }
    let label = "moe.uwucocoa.miso.metal.environment"
    let agent = home + "/Library/LaunchAgents/" + label + ".plist"
    if try data.contains(agent) {
      let properties = try data.plist(agent)
      guard properties["Label"] as? String == label,
        properties["ProgramArguments"] as? [String]
          == ["/bin/launchctl", "setenv", "TOOLCHAINS", identifier]
      else { throw MisoError.invalid("Refusing to remove an unrecognized Metal environment agent") }
      try FileManager.default.removeItem(at: data.path(agent))
    }
  }

  static func removingLegacySelection(_ existing: Data, configuration: XcodeConfiguration) throws
    -> Data
  {
    try configuration.validate()
    guard let text = String(data: existing, encoding: .utf8) else {
      throw MisoError.invalid("Invalid Metal shell configuration encoding")
    }
    let selection = "export TOOLCHAINS='moe.uwucocoa.miso.metal.\(configuration.build)'"
    return Data(
      text.components(separatedBy: "\n").filter { $0 != selection }.joined(separator: "\n").utf8)
  }
}

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
    public let contentSHA256: String
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
        configuration: configuration, catalog: original.path("catalog.jwt"),
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

  static func identifier(_ configuration: XcodeConfiguration) throws -> String {
    try configuration.validate()
    return "moe.uwucocoa.miso.metal." + configuration.build
  }

  static func copy(
    _ input: XcodeMetal.Receipt, configuration: XcodeConfiguration, inputs: URL,
    data: GuestVolume, account: BaseImageStage.Account, journal: ExecutionJournal
  ) throws -> Details {
    let disk = try GuestVolume(inputs).path(input.diskImage)
    let session = try DiskImageSession(image: disk, readOnly: true, journal: journal)
    let mount = journal.output.appendingPathComponent("metal-input")
    return try session.withAttachment(requireGPT: false, mountPoint: mount) { _ in
      let original = try GuestVolume(mount).directory("Metal.xctoolchain").url
      let info = try GuestVolume(original).plist("ToolchainInfo.plist")
      guard info["Identifier"] as? String == input.toolchainIdentifier else {
        throw MisoError.invalid("Authenticated Metal toolchain identity changed")
      }
      let path = "Library/Developer/MISO/Metal/\(configuration.build)/Metal.xctoolchain"
      let audit = try XcodeComponentPayload.copy(original, to: data, path: path, journal: journal)
      let executable = try data.path(path + "/usr/bin/metal")
      guard try SafeFile.sha256(executable) == input.metalSHA256 else {
        throw MisoError.invalid("Installed Metal executable differs")
      }
      try AppleCode.validate(executable)
      let registration = try register(
        configuration: configuration, payload: path, data: data, account: account)
      return Details(
        configuration: configuration, appleToolchainIdentifier: input.toolchainIdentifier,
        toolchainIdentifier: try identifier(configuration), payloadPath: path,
        registrationPath: registration, entries: audit.entries, contentSHA256: audit.contentSHA256)
    }
  }

  static func register(
    configuration: XcodeConfiguration, payload: String, data: GuestVolume,
    account: BaseImageStage.Account
  ) throws -> String {
    let identifier = try identifier(configuration)
    let path = "Library/Developer/Toolchains/MISO-Metal-\(configuration.build).xctoolchain"
    guard try !data.contains(path) else {
      throw MisoError.invalid("Metal toolchain registration already exists")
    }
    _ = try data.directory(payload + "/usr")
    let wrapper = try data.path(path, createParents: true)
    try SafeFile.makeDirectory(wrapper, mode: 0o755)
    try data.mergePlist(
      path + "/Info.plist",
      values: ["CFBundleIdentifier": identifier, "CompatibilityVersion": 2])
    let link = try data.path(path + "/usr")
    guard symlink("/" + payload + "/usr", link.path) == 0, lchmod(link.path, 0o755) == 0 else {
      throw MisoError.system("Register Metal toolchain payload", errno)
    }
    let home = "Users/" + account.username
    for profile in [".zshenv", ".zprofile"] {
      let relative = home + "/" + profile
      let present = try data.contains(relative)
      let previous = try present ? SafeFile.read(data.path(relative), limit: 1 << 20) : Data()
      let mode = try present ? FileMetadata.inspect(data.path(relative)).st_mode & 0o777 : 0o644
      try data.write(
        relative, data: shellProfile(previous, identifier: identifier),
        uid: account.uid, gid: account.gid, mode: mode)
    }
    let agent = "moe.uwucocoa.miso.metal.environment"
    let agentPath = home + "/Library/LaunchAgents/" + agent + ".plist"
    guard try !data.contains(agentPath) else {
      throw MisoError.invalid("Metal environment agent already exists")
    }
    for directory in [home + "/Library", home + "/Library/LaunchAgents"] {
      if try !data.contains(directory) {
        let url = try data.path(directory)
        try SafeFile.makeDirectory(url, mode: 0o755)
        guard chown(url.path, account.uid, account.gid) == 0 else {
          throw MisoError.system("Set Metal environment directory ownership", errno)
        }
      }
      _ = try data.directory(directory)
    }
    let properties: [String: Any] = [
      "Label": agent,
      "ProgramArguments": ["/bin/launchctl", "setenv", "TOOLCHAINS", identifier],
      "RunAtLoad": true, "LimitLoadToSessionType": "Aqua",
    ]
    try data.write(
      agentPath,
      data: PropertyListSerialization.data(
        fromPropertyList: properties, format: .binary, options: 0),
      uid: account.uid, gid: account.gid)
    return path
  }

  static func finalizeRegistration(configuration: XcodeConfiguration, data: GuestVolume) throws {
    guard configuration.components.contains(.metalToolchain) else { return }
    let identifier = try identifier(configuration)
    let payload = "Library/Developer/MISO/Metal/\(configuration.build)/Metal.xctoolchain/usr"
    let registration = "Library/Developer/Toolchains/MISO-Metal-\(configuration.build).xctoolchain"
    _ = try data.directory(payload)
    let properties = try data.plist(registration + "/Info.plist")
    let link = try data.path(registration + "/usr", allowLeafLink: true)
    let info = try FileMetadata.inspect(link)
    guard properties["CFBundleIdentifier"] as? String == identifier,
      properties["CompatibilityVersion"] as? Int == 2,
      info.st_mode & S_IFMT == S_IFLNK, info.st_uid == geteuid(), info.st_nlink == 1,
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/" + payload
    else { throw MisoError.invalid("Metal registration differs from its configured payload") }
    guard lchmod(link.path, 0o755) == 0 else {
      throw MisoError.system("Set Metal registration permissions", errno)
    }
  }

  static func shellProfile(_ existing: Data, identifier: String) throws -> Data {
    guard let text = String(data: existing, encoding: .utf8), !text.contains("TOOLCHAINS"),
      identifier.range(
        of: #"\Amoe\.uwucocoa\.miso\.metal\.[0-9]{2}[A-Z][0-9]{1,6}[a-z]?\z"#,
        options: .regularExpression) != nil
    else { throw MisoError.invalid("Invalid or conflicting Metal shell configuration") }
    let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
    return Data((text + separator + "export TOOLCHAINS='\(identifier)'\n").utf8)
  }
}

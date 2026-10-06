import Darwin
import Foundation

public enum XcodeFlutterInstallation {
  public struct Details: Encodable {
    let version: XcodeFlutterInputs.Version
    let packageConfigurationSHA256: String
    let payloadEntries: Int
    let profileSHA256: String
    let detachedPayloadVerified: Bool
    let runtimeVerified = false
  }

  public struct Receipt: Encodable {
    let input: XcodeFlutterInputs.Receipt
    let image: BaseStageReceipt<Details>
    let temporaryInputsRemoved: Bool
    let vmStarted = false
  }

  public static func install(
    source: URL, prepared: URL, configuration: XcodeConfiguration = .init(),
    output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Flutter installation requires administrator privileges")
    }
    try configuration.validate()
    let previous = try JSON.read(
      XcodeFlutterInputs.Receipt.self, from: GuestVolume(prepared).path("flutter.json"))
    let journal = try ExecutionJournal(
      output: output, operation: "install-xcode-flutter", cancellation: cancellation)
    do {
      let inputs = output.appendingPathComponent("inputs")
      let input = try await XcodeFlutterInputs.prepare(
        target: previous.target, output: inputs, cache: prepared, cancellation: journal.cancellation
      )
      let image = try BaseImageStage.run(
        source: source, output: output.appendingPathComponent("image"), operation: "xcode-flutter",
        layer: .xcode, cancellation: journal.cancellation
      ) { bundle, target, stage in
        guard target == input.target else {
          throw MisoError.invalid("Flutter target differs from image")
        }
        return try install(
          input, inputs: inputs, image: bundle.appendingPathComponent("disk.img"),
          configuration: configuration, username: username, journal: stage)
      }
      try BaseStageWorkspace.requireUnmounted(inputs)
      for path in ["flutter", "pub-cache", "source/checkout", input.dartArchive.path] {
        try FileManager.default.removeItem(at: inputs.appendingPathComponent(path))
      }
      let result = Receipt(input: input, image: image, temporaryInputsRemoved: true)
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  private static func install(
    _ input: XcodeFlutterInputs.Receipt, inputs: URL, image: URL, configuration: XcodeConfiguration,
    username: String,
    journal: ExecutionJournal
  ) throws -> Details {
    let session = try DiskImageSession(image: image, readOnly: false, journal: journal)
    let home = "Users/" + username
    let paths = [
      home + "/flutter", home + "/.pub-cache", home + "/.config/flutter", home + "/.dart-tool",
    ]
    var identity: [UInt32] = []
    var packageConfigurationSHA256 = ""
    var profileSHA256 = ""
    let payload = try session.withAttachment { attached in
      let data = try ImageMounts.mount(
        BaseImageStage.mainContainer(attached).volume(role: "Data"), session: attached,
        journal: journal, name: "flutter-data", readOnly: false)
      let account = try BaseImageStage.Account(username, data: data)
      identity = [account.uid, account.gid]
      _ = try XcodeArchive.inspect(
        data.directory(configuration.applicationPath).url, target: input.target,
        configuration: configuration)
      for path in paths {
        guard try !data.contains(path) else {
          throw MisoError.invalid("Flutter destination exists: \(path)")
        }
      }
      for (origin, destination, record) in [
        ("flutter", paths[0], input.sdkInventory), ("pub-cache", paths[1], input.pubInventory),
      ] {
        let entries = try JSON.read(
          [BaseInputArchive.Entry].self, from: Artifacts.resolve(record, under: inputs))
        try BaseFileTree.copy(
          inputs.appendingPathComponent(origin), to: data.path(destination), entries: entries,
          uid: account.uid, gid: account.gid, cancellation: journal.cancellation)
      }
      for path in paths.dropFirst(2) {
        try data.makeDirectories(path, uid: account.uid, gid: account.gid)
      }
      let packageConfiguration = paths[0] + "/" + FlutterPackageConfiguration.path
      let relocated = try FlutterPackageConfiguration.relocate(
        SafeFile.read(data.path(packageConfiguration), limit: 8 << 20),
        sourceSDK: inputs.appendingPathComponent("flutter"),
        sourceCache: inputs.appendingPathComponent("pub-cache"),
        sdk: URL(fileURLWithPath: "/" + paths[0]), cache: URL(fileURLWithPath: "/" + paths[1]),
        version: input.version.frameworkVersion)
      try data.write(packageConfiguration, data: relocated, uid: account.uid, gid: account.gid)
      packageConfigurationSHA256 = SafeFile.sha256(relocated)
      let profile = home + "/.zprofile"
      let bytes = try shellProfile(SafeFile.read(data.path(profile), limit: 1 << 20))
      let mode = try FileMetadata.inspect(data.path(profile)).st_mode & 0o777
      try data.write(profile, data: bytes, uid: account.uid, gid: account.gid, mode: mode)
      profileSHA256 = try SafeFile.sha256(data.path(profile))
      return try Dictionary(
        uniqueKeysWithValues: paths.map { path in
          let entries = try BaseFileTree.inventory(
            data, path: path, cancellation: journal.cancellation)
          try BaseFileTree.requireOwnership(
            data.path(path), entries: entries, uid: account.uid, gid: account.gid)
          return (path, entries)
        })
    }
    try SafeFile.writeNew(
      JSON.encode(payload), to: journal.output.appendingPathComponent("flutter-payload.json"))
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment { session in
      let data = try ImageMounts.mount(
        BaseImageStage.mainContainer(session).volume(role: "Data"), session: session,
        journal: journal, name: "flutter-audit", readOnly: true)
      let account = try BaseImageStage.Account(username, data: data)
      guard [account.uid, account.gid] == identity,
        try SafeFile.sha256(data.path(home + "/.zprofile")) == profileSHA256,
        try SafeFile.sha256(data.path(paths[0] + "/" + FlutterPackageConfiguration.path))
          == packageConfigurationSHA256
      else { throw MisoError.invalid("Detached Flutter account or profile differs") }
      for path in paths {
        guard let entries = payload[path],
          try BaseFileTree.inventory(data, path: path, cancellation: journal.cancellation)
            == entries
        else { throw MisoError.invalid("Detached Flutter payload differs") }
        try BaseFileTree.requireOwnership(
          data.path(path), entries: entries, uid: account.uid, gid: account.gid)
      }
    }
    return Details(
      version: input.version, packageConfigurationSHA256: packageConfigurationSHA256,
      payloadEntries: payload.values.reduce(0) { $0 + $1.count }, profileSHA256: profileSHA256,
      detachedPayloadVerified: true)
  }

  static func shellProfile(_ data: Data) throws -> Data {
    guard data.count <= 1 << 20, let text = String(data: data, encoding: .utf8),
      !text.contains("\0")
    else { throw MisoError.invalid("Invalid Flutter shell profile") }
    var result = text
    for line in [
      #"export FLUTTER_HOME="$HOME/flutter""#,
      #"export PUB_CACHE="$HOME/.pub-cache""#,
      #"export PATH="$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PATH""#,
    ] where !text.split(separator: "\n").contains(Substring(line)) {
      result += (result.isEmpty || result.hasSuffix("\n") ? "" : "\n") + line + "\n"
    }
    return Data(result.utf8)
  }
}

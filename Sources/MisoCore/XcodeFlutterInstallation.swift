import Darwin
import Foundation

public enum XcodeFlutterInstallation {
  public struct Details: Encodable {
    let version: XcodeFlutterInputs.Version
    let probes: [String: String]
    let payloadEntries: Int
    let profileSHA256: String
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
  }

  public struct Receipt: Encodable {
    let input: XcodeFlutterInputs.Receipt
    let image: BaseStageReceipt<Details>
    let temporaryInputsRemoved: Bool
    let vmStarted = false
  }

  public static func install(
    source: URL, prepared: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Flutter installation requires administrator privileges")
    }
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
          username: username, journal: stage)
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
    _ input: XcodeFlutterInputs.Receipt, inputs: URL, image: URL, username: String,
    journal: ExecutionJournal
  ) throws -> Details {
    let root = try BaseExecutionView.prepare(image: image, target: input.target, journal: journal)
    let home = "Users/" + username
    let paths = [
      home + "/flutter", home + "/.pub-cache", home + "/.config/flutter", home + "/.dart-tool",
    ]
    var identity: [UInt32] = []
    var probes: [String: String] = [:]
    var profileSHA256 = ""
    let payload = try GuestExecution.withSession(
      image: image, root: root, username: username, journal: journal
    ) { guest in
      try guest.verifyControls(target: input.target)
      identity = [guest.account.uid, guest.account.gid]
      let configuration = XcodeConfiguration()
      _ = try XcodeArchive.inspect(
        guest.data.directory(configuration.applicationPath).url, target: input.target,
        configuration: configuration)
      for path in paths {
        guard try !guest.data.contains(path) else {
          throw MisoError.invalid("Flutter destination exists: \(path)")
        }
      }
      for (origin, destination, record) in [
        ("flutter", paths[0], input.sdkInventory), ("pub-cache", paths[1], input.pubInventory),
      ] {
        let entries = try JSON.read(
          [BaseInputArchive.Entry].self, from: Artifacts.resolve(record, under: inputs))
        try BaseFileTree.copy(
          inputs.appendingPathComponent(origin), to: guest.data.path(destination), entries: entries,
          uid: guest.account.uid, gid: guest.account.gid, cancellation: journal.cancellation)
      }
      for path in paths.dropFirst(2) {
        try guest.data.makeDirectories(path, uid: guest.account.uid, gid: guest.account.gid)
      }
      let denied = home + "/.config/.miso-flutter-outside"
      guard try !guest.data.contains(denied) else {
        throw MisoError.invalid("Flutter control exists")
      }
      try guest.run(
        "flutter-outside-denial", arguments: ["/bin/sh", "-c", "printf denied > /" + denied],
        capability: .flutter, expectedExitCodes: [1, 2])
      guard try !guest.data.contains(denied) else {
        throw MisoError.invalid("Flutter isolation failed")
      }
      let sdk = "/" + paths[0]
      let dart = sdk + "/bin/cache/dart-sdk/bin/dart"
      let environment = [
        "/usr/bin/env", "PUB_CACHE=/" + paths[1], "CI=true", "FLUTTER_SUPPRESS_ANALYTICS=true",
        "ANDROID_HOME=/" + home + "/android-sdk", "ANDROID_SDK_ROOT=/" + home + "/android-sdk",
        "JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
      ]
      func run(_ name: String, _ arguments: [String], timeout: TimeInterval = 300) throws -> String
      {
        try guest.run(
          name, arguments: environment + arguments, capability: .flutter, timeout: timeout)
      }
      _ = try run(
        "flutter-offline-pub",
        [
          "/bin/sh", "-c", "cd \"$1/packages/flutter_tools\" && exec \"$2\" pub get --offline",
          "sh",
          sdk, dart,
        ])
      probes["precache"] = try run("flutter-offline-precache", [sdk + "/bin/flutter", "precache"])
      probes["version"] = try run(
        "flutter-version", [sdk + "/bin/flutter", "--version", "--machine"])
      let version = try JSONDecoder().decode(
        XcodeFlutterInputs.Version.self, from: Data((probes["version"] ?? "").utf8))
      guard version == input.version else {
        throw MisoError.invalid("Installed Flutter version differs")
      }
      let probe = "private/tmp/miso-flutter-" + UUID().uuidString
      try guest.data.makeDirectories(probe, uid: guest.account.uid, gid: guest.account.gid)
      let program = """
        int factorial(int n) => n < 2 ? 1 : n * factorial(n - 1);
        void main(List<String> args) {
          if (factorial(int.parse(args.single)) != 720) throw StateError('failed');
          print('dart-test-ok');
        }
        """ + "\n"
      try guest.data.write(
        probe + "/check.dart", data: Data(program.utf8), uid: guest.account.uid,
        gid: guest.account.gid, mode: 0o644)
      probes["dart-jit-test"] = try run(
        "dart-jit-test", [dart, "--disable-dart-dev", "/" + probe + "/check.dart", "6"])
      _ = try run(
        "dart-native-compile",
        [dart, "compile", "exe", "/" + probe + "/check.dart", "-o", "/" + probe + "/check"],
        timeout: 600)
      probes["dart-native-test"] = try run("dart-native-test", ["/" + probe + "/check", "6"])
      guard probes["dart-jit-test"] == "dart-test-ok", probes["dart-native-test"] == "dart-test-ok"
      else { throw MisoError.invalid("Dart executable test failed") }
      try FileManager.default.removeItem(at: guest.data.path(probe))
      let profile = home + "/.zprofile"
      let bytes = try shellProfile(SafeFile.read(guest.data.path(profile), limit: 1 << 20))
      let mode = try FileMetadata.inspect(guest.data.path(profile)).st_mode & 0o777
      try guest.data.write(
        profile, data: bytes, uid: guest.account.uid, gid: guest.account.gid, mode: mode)
      profileSHA256 = try SafeFile.sha256(guest.data.path(profile))
      return try Dictionary(
        uniqueKeysWithValues: paths.map { path in
          let entries = try BaseFileTree.inventory(
            guest.data, path: path, cancellation: journal.cancellation)
          try BaseFileTree.requireOwnership(
            guest.data.path(path), entries: entries, uid: guest.account.uid, gid: guest.account.gid)
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
        try SafeFile.sha256(data.path(home + "/.zprofile")) == profileSHA256
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
      version: input.version, probes: probes,
      payloadEntries: payload.values.reduce(0) { $0 + $1.count }, profileSHA256: profileSHA256,
      detachedPayloadVerified: true, executionControlsVerified: true)
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

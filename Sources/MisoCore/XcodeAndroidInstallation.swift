import Darwin
import Foundation

public enum XcodeAndroidInstallation {
  public struct Details: Encodable {
    let probes: [String: String]
    let payloadEntries: Int
    let profileSHA256: String
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
    let runtimeVerified = false
  }

  public struct Receipt: Encodable {
    let input: XcodeAndroidInputs.Receipt
    let image: BaseStageReceipt<Details>
    let temporaryInputsRemoved: Bool
    let vmStarted = false
  }

  public static func install(
    source: URL, prepared: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Android installation requires administrator privileges")
    }
    let previous = try JSON.read(
      XcodeAndroidInputs.Receipt.self, from: GuestVolume(prepared).path("android.json"))
    let journal = try ExecutionJournal(
      output: output, operation: "install-xcode-android", cancellation: cancellation)
    do {
      let inputs = output.appendingPathComponent("inputs")
      let input = try await XcodeAndroidInputs.prepare(
        target: previous.target, output: inputs, cache: prepared, cancellation: journal.cancellation
      )
      let image = try BaseImageStage.run(
        source: source, output: output.appendingPathComponent("image"), operation: "xcode-android",
        layer: .xcode, cancellation: journal.cancellation
      ) { bundle, target, stage in
        guard target == input.target else {
          throw MisoError.invalid("Android target differs from image")
        }
        return try install(
          input, inputs: inputs, image: bundle.appendingPathComponent("disk.img"),
          username: username, journal: stage)
      }
      try BaseStageWorkspace.requireUnmounted(inputs)
      for item in input.items {
        try FileManager.default.removeItem(
          at: inputs.appendingPathComponent(item.root).deletingLastPathComponent())
        try FileManager.default.removeItem(at: Artifacts.resolve(item.archive, under: inputs))
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
    _ input: XcodeAndroidInputs.Receipt, inputs: URL, image: URL, username: String,
    journal: ExecutionJournal
  ) throws -> Details {
    let root = try BaseExecutionView.prepare(image: image, target: input.target, journal: journal)
    let home = "Users/" + username
    let sdk = home + "/android-sdk"
    let paths = [sdk, home + "/.android"]
    let repository = try SafeFile.read(
      Artifacts.resolve(input.metadata, under: inputs), limit: 8 << 20)
    var probes: [String: String] = [:]
    var identity: [UInt32] = []
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
          throw MisoError.invalid("Android destination already exists: \(path)")
        }
        try guest.data.makeDirectories(path, uid: guest.account.uid, gid: guest.account.gid)
      }
      for item in input.items {
        let directory = item.package.identifier.replacingOccurrences(of: ";", with: "/")
        let destination = sdk + "/" + directory
        let inventory = try JSON.read(
          [BaseInputArchive.Entry].self, from: Artifacts.resolve(item.inventory, under: inputs))
        try guest.data.makeDirectories(
          (destination as NSString).deletingLastPathComponent,
          uid: guest.account.uid, gid: guest.account.gid)
        try BaseFileTree.copy(
          inputs.appendingPathComponent(item.root), to: guest.data.path(destination),
          entries: inventory, uid: guest.account.uid, gid: guest.account.gid,
          cancellation: journal.cancellation)
        let originalRoot = inputs.appendingPathComponent(item.root)
        let installedRoot = try guest.data.directory(destination).url
        for name in item.minimumMacOS.keys.sorted() {
          let original = originalRoot.appendingPathComponent(name).resolvingSymlinksInPath()
          let installed = installedRoot.appendingPathComponent(name).resolvingSymlinksInPath()
          guard original.path.hasPrefix(originalRoot.path + "/"),
            installed.path.hasPrefix(installedRoot.path + "/"),
            try SafeFile.sha256(installed) == SafeFile.sha256(original)
          else { throw MisoError.invalid("Installed Android executable differs from its input") }
          try journal.run(
            "verify-installed-android-signature",
            NativeCommand(
              .codesign, arguments: ["--verify", "--strict", installed.path], timeout: 90))
        }
        try guest.data.write(
          destination + "/package.xml",
          data: XcodeAndroidMetadata.localPackage(repository, package: item.package),
          uid: guest.account.uid, gid: guest.account.gid, mode: 0o644)
      }
      try guest.data.makeDirectories(
        sdk + "/licenses", uid: guest.account.uid, gid: guest.account.gid)
      for (name, terms) in input.selection.licenses {
        try guest.data.write(
          sdk + "/licenses/" + name,
          data: Data((XcodeAndroidMetadata.licenseDigest(terms) + "\n").utf8),
          uid: guest.account.uid, gid: guest.account.gid, mode: 0o644)
      }
      let denied = home + "/.miso-android-outside"
      guard try !guest.data.contains(denied) else {
        throw MisoError.invalid("Android control exists")
      }
      try guest.run(
        "android-outside-denial", arguments: ["/bin/sh", "-c", "printf denied > /" + denied],
        capability: .android, expectedExitCodes: [1, 2])
      guard try !guest.data.contains(denied) else {
        throw MisoError.invalid("Android isolation failed")
      }
      let java = "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
      let environment = [
        "/usr/bin/env", "JAVA_HOME=" + java, "ANDROID_HOME=/" + sdk, "ANDROID_SDK_ROOT=/" + sdk,
      ]
      func run(_ name: String, _ arguments: [String], timeout: TimeInterval = 180) throws -> String
      {
        try guest.run(
          name, arguments: environment + arguments, capability: .android, timeout: timeout)
      }
      let manager = "/" + sdk + "/cmdline-tools/20.0/bin/sdkmanager"
      probes["installed"] = try run(
        "android-installed", [manager, "--sdk_root=/" + sdk, "--list_installed"])
      try verifyInstalled(probes["installed"] ?? "", selection: input.selection)
      probes["licenses"] = try run(
        "android-licenses", [manager, "--sdk_root=/" + sdk, "--licenses"])
      guard probes["licenses"]?.contains("All SDK package licenses accepted.") == true else {
        throw MisoError.invalid("Android SDK licenses were not accepted")
      }
      let probe = "private/tmp/miso-android-" + UUID().uuidString
      try guest.data.makeDirectories(
        probe + "/classes", uid: guest.account.uid, gid: guest.account.gid)
      try guest.data.makeDirectories(probe + "/dex", uid: guest.account.uid, gid: guest.account.gid)
      try guest.data.write(
        probe + "/Check.java",
        data: Data(
          "public final class Check { public static void main(String[] args) { if (6 * 7 != 42) throw new AssertionError(); System.out.println(42); } }\n"
            .utf8), uid: guest.account.uid, gid: guest.account.gid, mode: 0o644)
      _ = try run(
        "android-javac",
        [
          java + "/bin/javac", "--release", "8", "-d", "/" + probe + "/classes",
          "/" + probe + "/Check.java",
        ])
      probes["java-test"] = try run(
        "android-java-test", [java + "/bin/java", "-cp", "/" + probe + "/classes", "Check"])
      guard probes["java-test"] == "42" else { throw MisoError.invalid("Java test failed") }
      _ = try run(
        "android-dex",
        [
          java + "/bin/java", "-cp", "/" + sdk + "/build-tools/36.0.0/lib/d8.jar",
          "com.android.tools.r8.D8", "--lib", "/" + sdk + "/platforms/android-36/android.jar",
          "--output", "/" + probe + "/dex", "/" + probe + "/classes/Check.class",
        ])
      let dex = try SafeFile.read(guest.data.path(probe + "/dex/classes.dex"), limit: 1 << 20)
      guard dex.starts(with: Data("dex\n".utf8)) else {
        throw MisoError.invalid("Android DEX output is invalid")
      }
      probes["dexSHA256"] = SafeFile.sha256(dex)
      try FileManager.default.removeItem(at: guest.data.path(probe))
      let profile = home + "/.zprofile"
      let data = try shellProfile(SafeFile.read(guest.data.path(profile), limit: 1 << 20))
      let mode = try FileMetadata.inspect(guest.data.path(profile)).st_mode & 0o777
      try guest.data.write(
        profile, data: data, uid: guest.account.uid, gid: guest.account.gid, mode: mode)
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
      JSON.encode(payload), to: journal.output.appendingPathComponent("android-payload.json"))
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment { session in
      let data = try ImageMounts.mount(
        BaseImageStage.mainContainer(session).volume(role: "Data"), session: session,
        journal: journal, name: "android-audit", readOnly: true)
      let account = try BaseImageStage.Account(username, data: data)
      guard [account.uid, account.gid] == identity,
        try SafeFile.sha256(data.path(home + "/.zprofile")) == profileSHA256
      else { throw MisoError.invalid("Detached Android account or profile differs") }
      for path in paths {
        guard let entries = payload[path],
          try BaseFileTree.inventory(data, path: path, cancellation: journal.cancellation)
            == entries
        else { throw MisoError.invalid("Detached Android payload differs") }
        try BaseFileTree.requireOwnership(
          data.path(path), entries: entries, uid: account.uid, gid: account.gid)
      }
    }
    return Details(
      probes: probes, payloadEntries: payload.values.reduce(0) { $0 + $1.count },
      profileSHA256: profileSHA256, detachedPayloadVerified: true, executionControlsVerified: true)
  }

  static func verifyInstalled(_ text: String, selection: XcodeAndroidInputs.Selection) throws {
    let rows = text.split(separator: "\n").map {
      $0.split(separator: "|", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
    }
    for package in selection.packages {
      let matches = rows.filter { $0.first == package.identifier }
      guard matches.count == 1, matches[0].count == 4,
        try StableVersion(matches[0][1]) == StableVersion(package.revision),
        matches[0][3] == package.identifier.replacingOccurrences(of: ";", with: "/")
      else { throw MisoError.invalid("Installed Android package differs: \(package.identifier)") }
    }
  }

  static func shellProfile(_ data: Data) throws -> Data {
    guard data.count <= 1 << 20, let text = String(data: data, encoding: .utf8),
      !text.contains("\0")
    else {
      throw MisoError.invalid("Invalid Android shell profile")
    }
    var result = text
    for line in [
      #"export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home""#,
      #"export ANDROID_HOME="$HOME/android-sdk""#,
      #"export ANDROID_SDK_ROOT="$ANDROID_HOME""#,
      #"export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/20.0/bin:$ANDROID_HOME/platform-tools:$PATH""#,
    ] where !text.split(separator: "\n").contains(Substring(line)) {
      result += (result.isEmpty || result.hasSuffix("\n") ? "" : "\n") + line + "\n"
    }
    return Data(result.utf8)
  }
}

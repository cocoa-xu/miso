import Darwin
import Foundation

public enum XcodeSimulatorTools {
  struct Formula: Codable, Equatable {
    let version: String
    let sha256: String

    var url: URL {
      URL(
        string:
          "https://github.com/wix/AppleSimulatorUtils/releases/download/\(version)/applesimutils-\(version).arm64_big_sur.bottle.tar.gz"
      )!
    }
  }

  public struct Inputs: Codable {
    let target: MacOSRelease
    let tap: GitSnapshot.Receipt
    let formula: Formula
    let source: ImageBundle.FileRecord
    let archive: ImageBundle.FileRecord
    let minimumMacOS: String
    let executableSHA256: String
    let vmStarted: Bool
  }

  public struct Details: Encodable {
    let inputs: Inputs
    let installed: [String: String]
    let executableSHA256: String
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
    let runtimeVerified = false
  }

  static func parse(_ data: Data) throws -> Formula {
    guard data.count <= 256 << 10, let text = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid applesimutils formula")
    }
    func captures(_ pattern: String) throws -> [[String]] {
      try NSRegularExpression(pattern: pattern).matches(
        in: text, range: NSRange(text.startIndex..., in: text)
      ).map { match in
        (1..<match.numberOfRanges).map {
          Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
      }
    }
    let roots = try captures(
      #"(?m)^\s*root_url ['"]https://github.com/wix/AppleSimulatorUtils/releases/download/([0-9.]+)['"]\s*$"#
    )
    let hashes = try captures(#"(?m)^\s*sha256 arm64_big_sur:\s*"([0-9a-f]{64})"\s*$"#)
    let requirements = try captures(#"(?m)^\s*depends_on\s+([^\n]+)$"#)
    guard roots.count == 1, hashes.count == 1,
      requirements == [[#"xcode: ["8.0", :build]"#]],
      try captures(
        #"(?m)^\s*(?:resource|patch|revision|version|on_macos|on_arm|on_intel)\b([^\n]*)"#
      ).isEmpty,
      try captures(#"(?m)^\s*bottle\s+do\s*$"#).count == 1
    else { throw MisoError.unsupported("Applesimutils formula requirements changed") }
    let version = roots[0][0]
    _ = try StableVersion(version)
    guard
      text.contains(
        "url 'https://github.com/wix/AppleSimulatorUtils/releases/download/\(version)/AppleSimulatorUtils-\(version).tar.gz'"
      )
    else {
      throw MisoError.invalid("Applesimutils source and bottle versions differ")
    }
    return Formula(version: version, sha256: hashes[0][0])
  }

  public static func prepare(
    target: MacOSRelease, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Inputs {
    _ = try RestoreProfile.select(target)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-simulator-tools", cancellation: cancellation)
    do {
      let tap = try await GitSnapshot.run(
        repository: "wix/homebrew-brew", output: output.appendingPathComponent("tap"),
        cache: cache?.appendingPathComponent("tap"), cancellation: journal.cancellation)
      let source = output.appendingPathComponent("tap/checkout/Formula/applesimutils.rb")
      let formula = try parse(SafeFile.read(source, limit: 256 << 10))
      let archive = output.appendingPathComponent("applesimutils.tar.gz")
      if let cache {
        let previous = try JSON.read(Inputs.self, from: GuestVolume(cache).path("tools.json"))
        guard previous.target == target, previous.formula == formula else {
          throw MisoError.invalid("Simulator tool cache differs from request")
        }
        try Artifacts.copy(
          Artifacts.resolve(previous.archive, under: cache), to: archive, maximumBytes: 16 << 20,
          cancellation: journal.cancellation)
      } else {
        try await HTTPFile.get(
          formula.url, to: archive, maximumBytes: 16 << 20, cancellation: journal.cancellation,
          redirects: .githubRelease)
      }
      guard try SafeFile.sha256(archive) == formula.sha256 else {
        throw MisoError.invalid("Simulator tool bottle checksum differs from tap")
      }
      let entries = try TarPayload.inspect(archive, cancellation: journal.cancellation)
      let prefix = "applesimutils/" + formula.version
      guard entries.count == 4,
        Set(entries.filter { $0.kind == S_IFDIR }.map(\.path)) == [
          "applesimutils", prefix, prefix + "/bin",
        ],
        entries.contains(where: {
          $0.path == prefix + "/bin/applesimutils" && $0.kind == S_IFREG && $0.mode & 0o111 != 0
            && $0.hardlink == nil
        })
      else { throw MisoError.unsupported("Simulator tool bottle layout changed") }
      let expanded = output.appendingPathComponent("expanded")
      try SafeFile.makeDirectory(expanded)
      try TarPayload.extract(
        archive, into: expanded, entries: entries, uid: getuid(), gid: getgid(),
        cancellation: journal.cancellation)
      let executable = try GuestVolume(expanded).path(prefix + "/bin/applesimutils")
      let minimum = try TapFormula.minimumMacOS(SafeFile.read(executable, limit: 16 << 20))
      guard minimum <= (try MacOSVersion(target.version)) else {
        throw MisoError.unsupported("Simulator tool requires a newer macOS")
      }
      try journal.run(
        "verify-simulator-tool-signature",
        NativeCommand(.codesign, arguments: ["--verify", "--strict", executable.path], timeout: 60))
      let result = Inputs(
        target: target, tap: tap, formula: formula,
        source: try Artifacts.record(source, relativeTo: output),
        archive: try Artifacts.record(archive, relativeTo: output),
        minimumMacOS: minimum.description, executableSHA256: try SafeFile.sha256(executable),
        vmStarted: false)
      try SafeFile.writeNew(JSON.encode(result), to: output.appendingPathComponent("tools.json"))
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  public static func install(
    source: URL, prepared: URL, configuration: XcodeConfiguration = .init(),
    output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) async throws -> BaseStageReceipt<Details> {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Simulator tool installation requires administrator privileges")
    }
    try configuration.validate()
    let previous = try JSON.read(Inputs.self, from: GuestVolume(prepared).path("tools.json"))
    let replay = output.appendingPathComponent("inputs")
    try SafeFile.makeDirectory(output)
    let inputs = try await prepare(
      target: previous.target, output: replay, cache: prepared, cancellation: cancellation)
    return try BaseImageStage.run(
      source: source, output: output.appendingPathComponent("image"),
      operation: "xcode-simulator-tools", layer: .xcode, cancellation: cancellation
    ) { bundle, target, journal in
      guard target == inputs.target else {
        throw MisoError.invalid("Simulator tool target differs from image")
      }
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      var installed: [String: String] = [:]
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        try guest.verifyControls(target: target)
        _ = try XcodeArchive.inspect(
          guest.data.directory(configuration.applicationPath).url, target: target,
          configuration: configuration)
        let execution = try HomebrewExecution(guest: guest)
        defer { try? execution.remove() }
        try execution.verify()
        func brew(_ name: String, _ arguments: [String]) throws -> String {
          try guest.run(
            name, arguments: GuestExecution.brewArguments(arguments, username: username),
            capability: .brew, timeout: 300)
        }
        var expected = try BaseBottles.installedVersions(
          brew("simulator-tools-before", ["list", "--formula", "--versions"]))
        guard expected["applesimutils"] == nil else {
          throw MisoError.invalid("Simulator tool already installed")
        }
        let tap = "opt/homebrew/Library/Taps/wix/homebrew-brew"
        try guest.data.makeDirectories(
          "opt/homebrew/Library/Taps/wix", uid: guest.account.uid, gid: guest.account.gid)
        guard try !guest.data.contains(tap) else {
          throw MisoError.invalid("Simulator tool tap already exists")
        }
        let checkout = replay.appendingPathComponent("tap/checkout")
        try BaseFileTree.copy(
          checkout, to: guest.data.path(tap),
          entries: BaseInputArchive.inventory(checkout, cancellation: journal.cancellation),
          uid: guest.account.uid, gid: guest.account.gid, cancellation: journal.cancellation)
        let fullName = "wix/brew/applesimutils"
        _ = try brew("trust-simulator-tool", ["trust", "--formula", fullName])
        let cached = try BaseTaps.cachePath(
          brew("simulator-tool-cache", ["--cache", "--force-bottle", fullName]), username: username)
        guard
          cached.hasSuffix("--applesimutils-\(inputs.formula.version).arm64_big_sur.bottle.tar.gz"),
          try !guest.data.contains(cached)
        else {
          throw MisoError.invalid("Unexpected simulator tool cache selection")
        }
        try guest.data.makeDirectories(
          (cached as NSString).deletingLastPathComponent,
          uid: guest.account.uid, gid: guest.account.gid)
        let destination = try guest.data.path(cached)
        try Artifacts.copy(
          Artifacts.resolve(inputs.archive, under: replay), to: destination,
          maximumBytes: inputs.archive.bytes, cancellation: journal.cancellation)
        guard chown(destination.path, guest.account.uid, guest.account.gid) == 0,
          chmod(destination.path, 0o444) == 0,
          try SafeFile.sha256(destination) == inputs.formula.sha256
        else { throw MisoError.invalid("Simulator tool staging differs") }
        _ = try brew(
          "install-simulator-tool",
          execution.rubyArguments(
            program: HomebrewExecution.installProgram(arguments: ["--force-bottle", fullName])))
        expected["applesimutils"] = inputs.formula.version
        installed = try BaseBottles.installedVersions(
          brew("simulator-tools-after", ["list", "--formula", "--versions"]))
        guard installed == expected else {
          throw MisoError.invalid("Simulator tool registry differs")
        }
        _ = try brew("simulator-tool-linkage", ["linkage", "--test", fullName])
        let executable = try guest.data.path(
          "opt/homebrew/Cellar/applesimutils/" + inputs.formula.version + "/bin/applesimutils")
        guard try SafeFile.sha256(executable) == inputs.executableSHA256 else {
          throw MisoError.invalid("Installed simulator tool differs from its signed input")
        }
        try journal.run(
          "verify-installed-simulator-tool-signature",
          NativeCommand(.codesign, arguments: ["--verify", "--strict", executable.path]))
        try execution.remove()
        let payload = try BaseFileTree.inventory(
          guest.data, path: "opt/homebrew", cancellation: journal.cancellation)
        try BaseFileTree.requireOwnership(
          guest.data.path("opt/homebrew"), entries: payload, uid: guest.account.uid,
          gid: guest.account.gid)
        return payload
      }
      try SafeFile.writeNew(
        JSON.encode(payload),
        to: journal.output.appendingPathComponent("simulator-tool-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let data = try ImageMounts.mount(
          BaseImageStage.mainContainer(session).volume(role: "Data"), session: session,
          journal: journal, name: "simulator-tool-audit", readOnly: true)
        guard
          try BaseFileTree.inventory(data, path: "opt/homebrew", cancellation: journal.cancellation)
            == payload
        else {
          throw MisoError.invalid("Detached simulator tool payload differs")
        }
      }
      return Details(
        inputs: inputs, installed: installed, executableSHA256: inputs.executableSHA256,
        detachedPayloadVerified: true,
        executionControlsVerified: true)
    }
  }
}

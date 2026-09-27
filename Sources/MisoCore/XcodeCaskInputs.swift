import Darwin
import Foundation

public enum XcodeCaskInputs {
  struct Cask: Codable, Equatable {
    let token: String
    let version: String
    let sha256: String
    let url: URL
    let sourceURL: URL
    let sourceSHA256: String

    var executable: String {
      switch token {
      case "codex": "bin/codex"
      case "kiro-cli": "Kiro CLI.app/Contents/MacOS/kiro-cli"
      default: "claude"
      }
    }

    var filename: String {
      switch token {
      case "codex": "payload.tar.gz"
      case "kiro-cli": "payload.dmg"
      default: "claude"
      }
    }
  }

  struct Item: Codable {
    let cask: Cask
    let metadata: ImageBundle.FileRecord
    let source: ImageBundle.FileRecord
    let archive: ImageBundle.FileRecord
    let inventory: ImageBundle.FileRecord
    let minimumMacOS: String
  }

  public struct Receipt: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let items: [Item]
    let vmStarted: Bool
    let installationVerified: Bool
  }

  static let tokens = ["codex", "kiro-cli", "claude-code"]

  static func parse(_ data: Data, token: String, target: MacOSRelease) throws -> Cask {
    guard tokens.contains(token),
      var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      fields["token"] as? String == token, fields["disabled"] as? Bool == false,
      let revision = fields["tap_git_head"] as? String,
      let sourcePath = fields["ruby_source_path"] as? String,
      let sourceSHA = (fields["ruby_source_checksum"] as? [String: String])?["sha256"]
    else { throw MisoError.invalid("Invalid developer cask metadata") }
    _ = try GitRemote.objectID(revision)
    guard sourcePath == "Casks/\(token.prefix(1))/\(token).rb" else {
      throw MisoError.invalid("Unexpected cask source path")
    }
    let family = try RestoreProfile.select(target).family
    let tag: String
    switch family {
    case .sequoia: tag = "arm64_sequoia"
    case .tahoe: tag = "arm64_tahoe"
    case .goldenGate: tag = "arm64_golden_gate"
    }
    if let variation = (fields["variations"] as? [String: [String: Any]])?[tag] {
      fields.merge(variation) { _, new in new }
    }
    guard let version = fields["version"] as? String, let sha = fields["sha256"] as? String,
      let address = fields["url"] as? String, let url = URL(string: address),
      let artifacts = fields["artifacts"] as? [[String: Any]], (1...16).contains(artifacts.count),
      let dependencies = fields["depends_on"] as? [String: Any],
      dependencies.keys.allSatisfy({ $0 == "macos" }),
      dependencies.isEmpty || (dependencies["macos"] as? [String: Any])?.isEmpty == true,
      artifacts.allSatisfy({
        Set($0.keys).isSubset(of: [
          "app", "binary", "target", "generate_completions_from_executable", "uninstall", "zap",
        ])
      })
    else { throw MisoError.unsupported("Developer cask artifacts or prerequisites changed") }
    try validateArtifacts(artifacts, token: token)
    _ = try StableVersion(version)
    try SafeFile.validateSHA256(sha)
    try SafeFile.validateSHA256(sourceSHA)
    let expected: String
    switch token {
    case "codex":
      expected =
        "https://github.com/openai/codex/releases/download/rust-v\(version)/codex-package-aarch64-apple-darwin.tar.gz"
    case "kiro-cli":
      expected = "https://desktop-release.q.us-east-1.amazonaws.com/\(version)/Kiro%20CLI.dmg"
    default:
      expected = "https://downloads.claude.ai/claude-code-releases/\(version)/darwin-arm64/claude"
    }
    guard url.absoluteString == expected else {
      throw MisoError.invalid("Unexpected arm64 cask payload URL")
    }
    return Cask(
      token: token, version: version, sha256: sha, url: url,
      sourceURL: URL(
        string: "https://raw.githubusercontent.com/Homebrew/homebrew-cask/\(revision)/\(sourcePath)"
      )!,
      sourceSHA256: sourceSHA)
  }

  static func validateArtifacts(_ artifacts: [[String: Any]], token: String) throws {
    let binary =
      token == "codex"
      ? "bin/codex"
      : token == "kiro-cli"
        ? "$APPDIR/Kiro CLI.app/Contents/MacOS/kiro-cli" : "claude"
    let command = token == "claude-code" ? "claude" : token
    var binaries = 0
    var applications = 0
    var completions = 0
    for artifact in artifacts {
      let kinds = Set(artifact.keys).subtracting(["target"])
      guard kinds.count == 1, let kind = kinds.first else {
        throw MisoError.invalid("Ambiguous cask artifact")
      }
      switch kind {
      case "binary":
        guard artifact[kind] as? [String] == [binary],
          artifact["target"] as? String == "$HOMEBREW_PREFIX/bin/" + command
        else { throw MisoError.unsupported("Cask executable layout changed") }
        binaries += 1
      case "app":
        guard token == "kiro-cli", artifact[kind] as? [String] == ["Kiro CLI.app"],
          artifact["target"] as? String == "/Applications/Kiro CLI.app"
        else { throw MisoError.unsupported("Cask application layout changed") }
        applications += 1
      case "generate_completions_from_executable":
        guard token == "codex", artifact["target"] == nil,
          let arguments = artifact[kind] as? [Any], arguments.count == 3,
          arguments[0] as? String == "bin/codex", arguments[1] as? String == "completion",
          let options = arguments[2] as? [String: Any],
          Set(options.keys) == ["base_name", "shell_parameter_format", "shells"],
          options["base_name"] is NSNull, options["shell_parameter_format"] is NSNull,
          options["shells"] as? [String] == ["bash", "zsh", "fish"]
        else { throw MisoError.unsupported("Cask completion generation changed") }
        completions += 1
      case "uninstall", "zap":
        guard artifact["target"] == nil else {
          throw MisoError.invalid("Unexpected cask removal target")
        }
      default: throw MisoError.unsupported("Unreviewed cask artifact")
      }
    }
    guard binaries == 1, applications == (token == "kiro-cli" ? 1 : 0),
      completions == (token == "codex" ? 1 : 0)
    else { throw MisoError.invalid("Required cask artifacts are missing or duplicated") }
  }

  public static func prepare(
    target: MacOSRelease, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    let cached = try cache.map(GuestVolume.init)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-casks", cancellation: cancellation)
    do {
      var items: [Item] = []
      try journal.setMetadata("target", value: target)
      try journal.setMetadata("cacheOnly", value: cache != nil)
      for token in tokens {
        try journal.setMetadata("preparing", value: token)
        let directory = output.appendingPathComponent(token)
        try SafeFile.makeDirectory(directory)
        let metadataURL = directory.appendingPathComponent("cask.json")
        let bytes: Data
        if let cached {
          bytes = try SafeFile.read(cached.path(token + "/cask.json"), limit: 1 << 20)
        } else {
          bytes = try await HTTPData.get(
            URL(string: "https://formulae.brew.sh/api/cask/\(token).json")!, maximumBytes: 1 << 20,
            cancellation: journal.cancellation)
        }
        try SafeFile.writeNew(bytes, to: metadataURL)
        let cask = try parse(bytes, token: token, target: target)
        let sourceURL = directory.appendingPathComponent("cask.rb")
        let source: Data
        if let cached {
          source = try SafeFile.read(cached.path(token + "/cask.rb"), limit: 1 << 20)
        } else {
          source = try await HTTPData.get(
            cask.sourceURL, maximumBytes: 1 << 20, cancellation: journal.cancellation)
        }
        try SafeFile.writeNew(source, to: sourceURL)
        guard try SafeFile.sha256(sourceURL) == cask.sourceSHA256 else {
          throw MisoError.invalid("Cask source differs from registry")
        }
        let archive = directory.appendingPathComponent(cask.filename)
        if let cached {
          try Artifacts.copy(
            cached.path(token + "/" + cask.filename), to: archive, maximumBytes: 512 << 20,
            cancellation: journal.cancellation)
        } else {
          try await HTTPFile.get(
            cask.url, to: archive, maximumBytes: 512 << 20, cancellation: journal.cancellation,
            redirects: token == "codex" ? .githubRelease : .reject)
        }
        guard try SafeFile.sha256(archive) == cask.sha256 else {
          throw MisoError.invalid("Cask archive checksum differs from source")
        }
        let expanded = directory.appendingPathComponent("expanded")
        try SafeFile.makeDirectory(expanded)
        switch token {
        case "codex":
          let entries = try TarPayload.inspect(archive, cancellation: journal.cancellation)
          try TarPayload.extract(
            archive, into: expanded, entries: entries, uid: getuid(), gid: getgid(),
            cancellation: journal.cancellation)
        case "kiro-cli":
          let session = try DiskImageSession(image: archive, readOnly: true, journal: journal)
          let mount = directory.appendingPathComponent("mount")
          try session.withAttachment(requireGPT: false, mountPoint: mount) { _ in
            let app = try GuestVolume(mount).directory("Kiro CLI.app").url
            try journal.run(
              "copy-cask-application",
              NativeCommand(
                .copy,
                arguments: [
                  "--rsrc", "--extattr", "--acl", app.path,
                  expanded.appendingPathComponent("Kiro CLI.app").path,
                ], timeout: 300))
          }
        default:
          let executable = expanded.appendingPathComponent("claude")
          try Artifacts.clone(archive, to: executable)
          guard chmod(executable.path, 0o755) == 0 else {
            throw MisoError.system("Set cask executable mode", errno)
          }
        }
        let executable = try GuestVolume(expanded).path(cask.executable)
        let minimum = try TapFormula.minimumMacOS(SafeFile.read(executable, limit: 512 << 20))
        guard try minimum <= MacOSVersion(target.version) else {
          throw MisoError.unsupported("Cask requires a newer macOS release")
        }
        let code =
          token == "kiro-cli" ? expanded.appendingPathComponent("Kiro CLI.app") : executable
        try journal.run(
          "verify-cask-signature",
          NativeCommand(
            .codesign, arguments: ["--verify", "--deep", "--strict", code.path], timeout: 180))
        let inventory = try BaseInputArchive.inventory(expanded, cancellation: journal.cancellation)
        let inventoryURL = directory.appendingPathComponent("inventory.json")
        try SafeFile.writeNew(JSON.encode(inventory), to: inventoryURL)
        items.append(
          Item(
            cask: cask,
            metadata: try Artifacts.record(metadataURL, relativeTo: output),
            source: try Artifacts.record(sourceURL, relativeTo: output),
            archive: try Artifacts.record(archive, relativeTo: output),
            inventory: try Artifacts.record(inventoryURL, relativeTo: output),
            minimumMacOS: minimum.description))
      }
      let result = Receipt(
        schemaVersion: 1, target: target, items: items, vmStarted: false,
        installationVerified: false)
      try SafeFile.writeNew(JSON.encode(result), to: output.appendingPathComponent("casks.json"))
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

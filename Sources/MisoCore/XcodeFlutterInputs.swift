import CryptoKit
import Darwin
import Foundation

public enum XcodeFlutterInputs {
  struct Version: Codable, Equatable {
    let frameworkVersion: String
    let channel: String
    let frameworkRevision: String
    let engineRevision: String
    let dartSdkVersion: String
  }

  struct DartObject: Codable {
    let name: String
    let size: String
    let md5Hash: String
    let generation: String

    func validate(engine: String) throws -> UInt64 {
      guard name == "flutter/" + engine + "/dart-sdk-darwin-arm64.zip",
        let bytes = UInt64(size), (1...(512 << 20)).contains(bytes),
        Data(base64Encoded: md5Hash)?.count == 16, UInt64(generation) != nil
      else { throw MisoError.invalid("Invalid Flutter Dart object metadata") }
      return bytes
    }
  }

  public struct Receipt: Codable {
    let target: MacOSRelease
    let source: GitSnapshot.Receipt
    let tags: ImageBundle.FileRecord
    let dartMetadata: ImageBundle.FileRecord
    let dartArchive: ImageBundle.FileRecord
    let sdkInventory: ImageBundle.FileRecord
    let pubInventory: ImageBundle.FileRecord
    let version: Version
    let vmStarted: Bool
    let installationVerified: Bool
  }

  static func stableVersion(source: GitSnapshot.Receipt, capabilities: Data, tags: Data) throws
    -> String
  {
    let remote = try GitRemote(capabilities: capabilities, references: tags)
    let matches = remote.references.values.filter {
      $0.commitID == source.selection.commitID && $0.objectID == $0.commitID
        && $0.reference.range(
          of: #"\Arefs/tags/[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil
    }
    guard matches.count == 1 else {
      throw MisoError.invalid("Stable Flutter commit has no unique release tag")
    }
    return String(matches[0].reference.dropFirst("refs/tags/".count))
  }

  public static func prepare(
    target: MacOSRelease, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-flutter", cancellation: cancellation)
    do {
      let previous = try cache.map {
        try JSON.read(Receipt.self, from: GuestVolume($0).path("flutter.json"))
      }
      if let previous, previous.target != target {
        throw MisoError.invalid("Flutter cache target differs")
      }
      let source = try await GitSnapshot.run(
        repository: "flutter/flutter", reference: "refs/heads/stable",
        output: output.appendingPathComponent("source"),
        cache: cache?.appendingPathComponent("source"),
        cancellation: journal.cancellation)
      let tags = output.appendingPathComponent("tags.bin")
      if let previous, let cache {
        try Artifacts.copy(
          Artifacts.resolve(previous.tags, under: cache), to: tags, maximumBytes: 8 << 20)
      } else {
        try await HTTPFile.post(
          URL(string: "https://github.com/flutter/flutter.git/git-upload-pack")!,
          body: GitRemote.referenceRequest("refs/tags/"),
          contentType: "application/x-git-upload-pack-request",
          to: tags, maximumBytes: 8 << 20, cancellation: journal.cancellation, gitProtocolV2: true)
      }
      let version = try stableVersion(
        source: source,
        capabilities: SafeFile.read(
          output.appendingPathComponent("source/capabilities.bin"), limit: 65536),
        tags: SafeFile.read(tags, limit: 8 << 20))
      let engine = try engineVersion(output.appendingPathComponent("source/checkout"))
      let metadata = output.appendingPathComponent("dart-object.json")
      let archive = output.appendingPathComponent("dart-sdk-darwin-arm64.zip")
      if let previous, let cache {
        try Artifacts.copy(
          Artifacts.resolve(previous.dartMetadata, under: cache), to: metadata, maximumBytes: 65536)
        try Artifacts.copy(
          Artifacts.resolve(previous.dartArchive, under: cache), to: archive,
          maximumBytes: 512 << 20)
      } else {
        let objectURL = URL(
          string: "https://storage.googleapis.com/storage/v1/b/flutter_infra_release/o/flutter%2F"
            + engine + "%2Fdart-sdk-darwin-arm64.zip")!
        try SafeFile.writeNew(
          try await HTTPData.get(
            objectURL, maximumBytes: 65536, cancellation: journal.cancellation), to: metadata)
        let object = try JSON.read(DartObject.self, from: metadata)
        let bytes = try object.validate(engine: engine)
        try await HTTPFile.get(
          URL(string: "https://storage.googleapis.com/flutter_infra_release/" + object.name)!,
          to: archive, maximumBytes: bytes, cancellation: journal.cancellation)
      }
      try validateDart(
        archive, metadata: metadata, engine: engine, cancellation: journal.cancellation)
      let flutter = output.appendingPathComponent("flutter")
      let pub = output.appendingPathComponent("pub-cache")
      if let previous, let cache {
        for (path, record) in [
          ("flutter", previous.sdkInventory), ("pub-cache", previous.pubInventory),
        ] {
          let entries = try JSON.read(
            [BaseInputArchive.Entry].self, from: Artifacts.resolve(record, under: cache))
          try BaseFileTree.copy(
            cache.appendingPathComponent(path), to: output.appendingPathComponent(path),
            entries: entries, uid: getuid(), gid: getgid(), cancellation: journal.cancellation)
        }
      } else {
        let checkout = output.appendingPathComponent("source/checkout")
        try BaseFileTree.copy(
          checkout, to: flutter,
          entries: BaseInputArchive.inventory(checkout, cancellation: journal.cancellation),
          uid: getuid(), gid: getgid(), cancellation: journal.cancellation)
        try SafeFile.makeDirectory(pub)
        try ZIPPayload.extract(
          archive, to: flutter.appendingPathComponent("bin/cache"),
          cancellation: journal.cancellation)
        try SafeFile.writeNew(
          Data((engine + "\n").utf8),
          to: flutter.appendingPathComponent("bin/cache/engine-dart-sdk.stamp"))
      }
      try verifySource(output: output, cancellation: journal.cancellation)
      for arguments in [
        ["update-ref", "refs/heads/stable", source.selection.commitID],
        ["update-ref", "refs/tags/" + version, source.selection.commitID],
        ["symbolic-ref", "HEAD", "refs/heads/stable"],
      ] {
        try journal.run(
          "bind-flutter-reference",
          NativeCommand("/usr/bin/git", arguments: ["-C", flutter.path] + arguments))
      }
      let result = try finish(
        target: target, source: source, output: output, offline: cache != nil, journal: journal)
      if let previous, result.version != previous.version {
        throw MisoError.invalid("Replayed Flutter version differs")
      }
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  static func engineVersion(_ sdk: URL) throws -> String {
    let text = String(
      decoding: try SafeFile.read(
        sdk.appendingPathComponent("bin/internal/engine.version"), limit: 128), as: UTF8.self
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try GitRemote.objectID(text)
    return text
  }

  static func validateDart(
    _ archive: URL, metadata: URL, engine: String, cancellation: CancellationToken?
  ) throws {
    let object = try JSON.read(DartObject.self, from: metadata)
    let expected = try object.validate(engine: engine)
    let file = try SafeFile.openRegular(archive)
    defer { try? file.close() }
    var remaining = try SafeFile.size(file)
    guard remaining == expected else { throw MisoError.invalid("Dart archive size differs") }
    var digest = Insecure.MD5()
    while remaining > 0 {
      try cancellation?.check()
      let count = Int(min(remaining, 1 << 20))
      digest.update(data: try file.readExactly(count))
      remaining -= UInt64(count)
    }
    guard Data(digest.finalize()) == Data(base64Encoded: object.md5Hash) else {
      throw MisoError.invalid("Dart archive differs from Google object digest")
    }
  }

  static func verifySource(output: URL, cancellation: CancellationToken?) throws {
    let original = output.appendingPathComponent("source/checkout")
    let source = try BaseInputArchive.inventory(original, cancellation: cancellation)
    let flutter = try GuestVolume(output.appendingPathComponent("flutter"))
    for entry in source
    where entry.path != "." && entry.path != ".git" && !entry.path.hasPrefix(".git/") {
      try cancellation?.check()
      let file = try flutter.path(entry.path, allowLeafLink: true)
      let info = try FileMetadata.inspect(file)
      switch entry.kind {
      case "directory":
        guard info.st_mode & S_IFMT == S_IFDIR else {
          throw MisoError.invalid("Flutter source directory changed")
        }
      case "file":
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == entry.mode,
          try SafeFile.sha256(file) == entry.sha256
        else { throw MisoError.invalid("Flutter source file changed: \(entry.path)") }
      case "symlink":
        guard info.st_mode & S_IFMT == S_IFLNK,
          try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == entry.link
        else { throw MisoError.invalid("Flutter source link changed") }
      default: throw MisoError.invalid("Invalid Flutter source entry")
      }
    }
    for path in [".git/config", ".git/shallow"] {
      guard
        try SafeFile.sha256(original.appendingPathComponent(path))
          == SafeFile.sha256(flutter.path(path))
      else { throw MisoError.invalid("Flutter Git configuration changed") }
    }
  }

  static func finish(
    target: MacOSRelease, source: GitSnapshot.Receipt, output: URL, offline: Bool,
    journal: ExecutionJournal
  ) throws -> Receipt {
    let flutter = output.appendingPathComponent("flutter")
    let engine = try engineVersion(output.appendingPathComponent("source/checkout"))
    let version = try stableVersion(
      source: source,
      capabilities: SafeFile.read(
        output.appendingPathComponent("source/capabilities.bin"), limit: 65536),
      tags: SafeFile.read(output.appendingPathComponent("tags.bin"), limit: 8 << 20))
    try validateDart(
      output.appendingPathComponent("dart-sdk-darwin-arm64.zip"),
      metadata: output.appendingPathComponent("dart-object.json"), engine: engine,
      cancellation: journal.cancellation)
    try verifySource(output: output, cancellation: journal.cancellation)
    let dart = flutter.appendingPathComponent("bin/cache/dart-sdk/bin/dart")
    guard
      try TapFormula.minimumMacOS(SafeFile.read(dart, limit: 512 << 20))
        <= MacOSVersion(target.version)
    else { throw MisoError.unsupported("Flutter Dart requires newer macOS") }
    try journal.run(
      "verify-dart-signature",
      NativeCommand(.codesign, arguments: ["--verify", "--strict", dart.path]))
    for name in ["home", "tmp", "config", "cache"] {
      try SafeFile.makeDirectory(output.appendingPathComponent(name))
    }
    let environment = [
      "HOME": output.appendingPathComponent("home").path,
      "PUB_CACHE": output.appendingPathComponent("pub-cache").path,
      "TMPDIR": output.appendingPathComponent("tmp").path + "/",
      "XDG_CONFIG_HOME": output.appendingPathComponent("config").path,
      "XDG_CACHE_HOME": output.appendingPathComponent("cache").path, "CI": "true",
      "FLUTTER_SUPPRESS_ANALYTICS": "true",
    ]
    guard output.path.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else {
      throw MisoError.invalid("Invalid Flutter sandbox path")
    }
    let sandboxPath = output.path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let policy =
      "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"" + sandboxPath
      + "\")(subpath \"/private/tmp\")(literal \"/dev/null\"))" + (offline ? "(deny network*)" : "")
    func run(_ name: String, _ arguments: [String], directory: URL, timeout: TimeInterval) throws
      -> URL
    {
      try journal.run(
        name,
        NativeCommand(
          "/usr/bin/sandbox-exec", arguments: ["-p", policy] + arguments, timeout: timeout,
          environment: environment, workingDirectory: directory))
    }
    if offline {
      _ = try run(
        "flutter-offline-pub", [dart.path, "pub", "get", "--offline"],
        directory: flutter.appendingPathComponent("packages/flutter_tools"), timeout: 300)
    }
    _ = try run(
      "flutter-precache", [flutter.appendingPathComponent("bin/flutter").path, "precache"],
      directory: flutter, timeout: offline ? 300 : 5400)
    let versionOutput = try run(
      "flutter-version",
      [flutter.appendingPathComponent("bin/flutter").path, "--version", "--machine"],
      directory: flutter, timeout: 180)
    let actual = try JSON.read(Version.self, from: versionOutput)
    guard actual.frameworkVersion == version, actual.frameworkRevision == source.selection.commitID,
      actual.channel == "stable", actual.engineRevision == engine
    else { throw MisoError.invalid("Flutter version differs from authenticated source") }
    _ = try StableVersion(actual.dartSdkVersion)
    try verifySource(output: output, cancellation: journal.cancellation)
    for (path, name) in [("flutter", "sdk-inventory.json"), ("pub-cache", "pub-inventory.json")] {
      try SafeFile.writeNew(
        JSON.encode(
          BaseInputArchive.inventory(
            output.appendingPathComponent(path), cancellation: journal.cancellation)),
        to: output.appendingPathComponent(name))
    }
    let receipt = Receipt(
      target: target, source: source,
      tags: try Artifacts.record(output.appendingPathComponent("tags.bin"), relativeTo: output),
      dartMetadata: try Artifacts.record(
        output.appendingPathComponent("dart-object.json"), relativeTo: output),
      dartArchive: try Artifacts.record(
        output.appendingPathComponent("dart-sdk-darwin-arm64.zip"), relativeTo: output),
      sdkInventory: try Artifacts.record(
        output.appendingPathComponent("sdk-inventory.json"), relativeTo: output),
      pubInventory: try Artifacts.record(
        output.appendingPathComponent("pub-inventory.json"), relativeTo: output), version: actual,
      vmStarted: false, installationVerified: false)
    try SafeFile.writeNew(JSON.encode(receipt), to: output.appendingPathComponent("flutter.json"))
    return receipt
  }
}

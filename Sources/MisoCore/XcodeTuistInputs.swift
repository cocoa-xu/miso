import Darwin
import Foundation

public enum XcodeTuistInputs {
  struct Formula: Codable, Equatable {
    let version: String
    let sha256: String

    var url: URL {
      URL(string: "https://github.com/tuist/tuist/releases/download/\(version)/tuist.zip")!
    }
  }

  public struct Receipt: Codable {
    let target: MacOSRelease
    let tap: GitSnapshot.Receipt
    let formula: Formula
    let source: ImageBundle.FileRecord
    let archive: ImageBundle.FileRecord
    let inventory: ImageBundle.FileRecord
    let minimumMacOS: String
    let vmStarted: Bool
    let installationVerified: Bool
  }

  static func parse(_ data: Data, version: String) throws -> Formula {
    _ = try StableVersion(version)
    guard data.count <= 256 << 10, let source = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid Tuist formula source")
    }
    func matches(_ pattern: String) throws -> [String] {
      try NSRegularExpression(pattern: pattern).matches(
        in: source, range: NSRange(source.startIndex..., in: source)
      ).map {
        Range($0.range(at: 1), in: source).map { String(source[$0]) } ?? ""
      }
    }
    guard
      try matches(#"(?m)^\s*url "([^"]+)"\s*$"#) == [
        "https://github.com/tuist/tuist/releases/download/\(version)/tuist.zip"
      ],
      try matches(#"(?m)^\s*depends_on ([^\n]+)$"#) == ["macos: :monterey"],
      try matches(#"(?m)^\s*(resource|patch|bottle|revision|version|on_arm|on_intel)\b"#).isEmpty
    else { throw MisoError.unsupported("Tuist formula payload or prerequisites changed") }
    let hashes = try matches(#"(?m)^\s*sha256 "([0-9a-f]{64})"\s*$"#)
    guard hashes.count == 1 else { throw MisoError.invalid("Missing or ambiguous Tuist checksum") }
    return Formula(version: version, sha256: hashes[0])
  }

  public static func prepare(
    target: MacOSRelease, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-tuist", cancellation: cancellation)
    do {
      let tap = try await GitSnapshot.run(
        repository: "tuist/homebrew-tuist", output: output.appendingPathComponent("tap"),
        cache: cache?.appendingPathComponent("tap"), cancellation: journal.cancellation)
      let checkout = try GuestVolume(output.appendingPathComponent("tap/checkout"))
      let alias = try checkout.path("Aliases/tuist", allowLeafLink: true)
      guard try FileMetadata.inspect(alias).st_mode & S_IFMT == S_IFLNK else {
        throw MisoError.invalid("Tuist stable alias is not a symbolic link")
      }
      let link = try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)
      let prefix = "../Formula/tuist@"
      guard link.hasPrefix(prefix), link.hasSuffix(".rb") else {
        throw MisoError.invalid("Tuist stable alias escapes the versioned formula layout")
      }
      let version = String(link.dropFirst(prefix.count).dropLast(3))
      _ = try StableVersion(version)
      let source = try checkout.path("Formula/tuist@\(version).rb")
      let formula = try parse(SafeFile.read(source, limit: 256 << 10), version: version)
      let archive = output.appendingPathComponent("tuist.zip")
      if let cache {
        let previous = try JSON.read(Receipt.self, from: GuestVolume(cache).path("tuist.json"))
        guard previous.target == target, previous.formula == formula else {
          throw MisoError.invalid("Tuist input cache differs from request")
        }
        try Artifacts.copy(
          Artifacts.resolve(previous.archive, under: cache), to: archive, maximumBytes: 512 << 20,
          cancellation: journal.cancellation)
      } else {
        try await HTTPFile.get(
          formula.url, to: archive, maximumBytes: 512 << 20, cancellation: journal.cancellation,
          redirects: .githubRelease)
      }
      guard try SafeFile.sha256(archive) == formula.sha256 else {
        throw MisoError.invalid("Tuist archive differs from the pinned formula checksum")
      }
      let expanded = output.appendingPathComponent("expanded")
      try ZIPPayload.extract(
        archive, to: expanded, maximumBytes: 2 << 30, cancellation: journal.cancellation)
      let tree = try GuestVolume(expanded)
      let tool = try tree.path("tuist")
      guard try FileMetadata.inspect(tool).st_mode & 0o111 != 0 else {
        throw MisoError.invalid("Tuist executable permissions are missing")
      }
      let minimum = try TapFormula.minimumMacOS(SafeFile.read(tool, limit: 256 << 20))
      guard minimum <= (try MacOSVersion(target.version)) else {
        throw MisoError.unsupported("Tuist requires a newer macOS")
      }
      for path in [tool, try tree.directory("ProjectDescription.framework").url] {
        try journal.run(
          "verify-tuist-signature",
          NativeCommand(
            .codesign,
            arguments: [
              "--verify", "--deep", "--strict", "-R",
              "=anchor apple generic and certificate leaf[subject.OU] = \"U6LC622NKF\"", path.path,
            ], timeout: 120))
      }
      let inventory = output.appendingPathComponent("inventory.json")
      try SafeFile.writeNew(
        JSON.encode(BaseInputArchive.inventory(expanded, cancellation: journal.cancellation)),
        to: inventory)
      let result = Receipt(
        target: target, tap: tap, formula: formula,
        source: try Artifacts.record(source, relativeTo: output),
        archive: try Artifacts.record(archive, relativeTo: output),
        inventory: try Artifacts.record(inventory, relativeTo: output),
        minimumMacOS: minimum.description,
        vmStarted: false, installationVerified: false)
      try SafeFile.writeNew(JSON.encode(result), to: output.appendingPathComponent("tuist.json"))
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

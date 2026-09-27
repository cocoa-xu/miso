import Darwin
import Foundation

public enum BaseRunnerResolution {
  struct Release {
    let version: String
    let name: String
    let url: URL
    let sha256: String
    let bytes: UInt64

    init(_ data: Data, requested: String?) throws {
      guard data.count <= 2 << 20,
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["draft"] as? Bool == false, value["prerelease"] as? Bool == false,
        let tag = value["tag_name"] as? String, tag.hasPrefix("v"),
        let assets = value["assets"] as? [[String: Any]], assets.count <= 100
      else { throw MisoError.invalid("Invalid Actions Runner release metadata") }
      version = String(tag.dropFirst())
      _ = try StableVersion(version)
      if let requested {
        _ = try StableVersion(requested)
        guard requested == version else {
          throw MisoError.invalid("Actions Runner release differs from requested version")
        }
      }
      let name = "actions-runner-osx-arm64-\(version).tar.gz"
      let matches = assets.filter { $0["name"] as? String == name }
      let expected = "https://github.com/actions/runner/releases/download/\(tag)/\(name)"
      guard matches.count == 1, let asset = matches.first,
        asset["browser_download_url"] as? String == expected,
        let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"),
        let size = asset["size"] as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(),
        size.doubleValue == Double(size.uint64Value), (1...(512 << 20)).contains(size.uint64Value)
      else { throw MisoError.invalid("Invalid Actions Runner arm64 asset") }
      sha256 = String(digest.dropFirst(7))
      try SafeFile.validateSHA256(sha256)
      url = URL(string: expected)!
      self.name = name
      bytes = size.uint64Value
    }
  }

  public struct Receipt: Encodable {
    let schemaVersion: Int
    let target: MacOSRelease
    let requestedVersion: String?
    let version: String
    let release: ImageBundle.FileRecord
    let runner: ImageBundle.FileRecord
    let sourceURL: URL
    let executableMinimumMacOS: [String: String]
    let installationVerified: Bool
    let runtimeVerified: Bool
  }

  static func inspect(
    _ archive: URL, target: MacOSRelease, cancellation: CancellationToken?
  ) throws -> [String: String] {
    let entries = try TarPayload.inspect(archive, cancellation: cancellation)
    guard
      entries.contains(where: {
        $0.path == "run.sh" && $0.kind == S_IFREG && $0.mode & 0o111 != 0
          && $0.link == nil && $0.hardlink == nil
      })
    else { throw MisoError.invalid("Missing Actions Runner entry point") }
    let node = entries.filter {
      $0.path.range(of: #"\Aexternals/node[0-9]+/bin/node\z"#, options: .regularExpression) != nil
    }.map(\.path)
    guard !node.isEmpty, node.count <= 16 else {
      throw MisoError.invalid("Missing or excessive Actions Runner Node runtimes")
    }
    let paths = ["bin/Runner.Listener", "bin/Runner.Worker"] + node.sorted()
    var versions: [String: String] = [:]
    for path in paths {
      guard let entry = entries.first(where: { $0.path == path }),
        entry.kind == S_IFREG, entry.mode & 0o111 != 0,
        entry.link == nil, entry.hardlink == nil
      else { throw MisoError.invalid("Missing Actions Runner executable: \(path)") }
      let bytes = try TarPayload.file(
        archive, path: path, maximumBytes: 128 << 20, cancellation: cancellation)
      let minimum = try BasePackageResolution.minimumMacOS(bytes)
      guard try MacOSVersion(target.version) >= minimum else {
        throw MisoError.unsupported("Actions Runner executable excludes target macOS: \(path)")
      }
      versions[path] = minimum.description
    }
    return versions
  }

  public static func run(
    target: MacOSRelease, version: String? = nil, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    if let version { _ = try StableVersion(version) }
    let cached = try cache.map { try GuestVolume($0) }
    let journal = try ExecutionJournal(
      output: output, operation: "resolve-base-runner", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: target)
      let bytes: Data
      if let cached {
        bytes = try SafeFile.read(cached.path("release.json"), limit: 2 << 20)
      } else {
        let selector = version.map { "tags/v" + $0 } ?? "latest"
        bytes = try await HTTPData.get(
          URL(string: "https://api.github.com/repos/actions/runner/releases/" + selector)!,
          maximumBytes: 2 << 20, cancellation: journal.cancellation)
      }
      let release = try Release(bytes, requested: version)
      try SafeFile.writeNew(bytes, to: output.appendingPathComponent("release.json"))
      let archive = output.appendingPathComponent(release.name)
      if let cached {
        try Artifacts.copy(
          cached.path(release.name), to: archive, maximumBytes: release.bytes,
          cancellation: journal.cancellation)
      } else {
        try await HTTPFile.get(
          release.url, to: archive, maximumBytes: release.bytes,
          cancellation: journal.cancellation, redirects: .githubRelease)
      }
      let record = try Artifacts.record(archive, relativeTo: output)
      guard record.sha256 == release.sha256, record.bytes == release.bytes else {
        throw MisoError.invalid("Actions Runner archive differs from release checksum or size")
      }
      let minimum = try inspect(archive, target: target, cancellation: journal.cancellation)
      guard try Artifacts.record(archive, relativeTo: output) == record else {
        throw MisoError.invalid("Actions Runner archive changed during inspection")
      }
      let receipt = Receipt(
        schemaVersion: 1, target: target, requestedVersion: version, version: release.version,
        release: try Artifacts.record(
          output.appendingPathComponent("release.json"), relativeTo: output),
        runner: record, sourceURL: release.url, executableMinimumMacOS: minimum,
        installationVerified: false, runtimeVerified: false)
      try SafeFile.writeNew(
        JSON.encode(receipt), to: output.appendingPathComponent("resolution.json"))
      try journal.finish(receipt)
      return receipt
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

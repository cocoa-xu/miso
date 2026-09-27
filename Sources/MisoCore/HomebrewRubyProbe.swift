import Foundation

struct HomebrewRubyProbe: Codable, Equatable {
  let version: String
  let commit: String
  let vendorVersion: ImageBundle.FileRecord
  let vendorPlatform: ImageBundle.FileRecord
  let payload: ImageBundle.FileRecord
  let minimumMacOS: String

  static func run(
    version: String, commit: String, output: URL, cache: URL?, previous: Self?,
    legacyPayload: ImageBundle.FileRecord?, cancellation: CancellationToken
  ) async throws -> Self {
    var records: [ImageBundle.FileRecord] = []
    for (name, cached) in [
      ("portable-ruby-version", previous?.vendorVersion),
      ("portable-ruby-arm64-darwin", previous?.vendorPlatform),
    ] {
      let relative = "compatibility/\(version)-\(name)"
      let path = output.appendingPathComponent(relative)
      let data: Data
      if let cache {
        if let previous, let cached {
          guard previous.version == version, previous.commit == commit,
            cached.path == relative, cached.bytes <= 4096
          else { throw MisoError.invalid("Portable Ruby probe differs from request") }
          data = try SafeFile.read(
            Artifacts.resolve(cached, under: cache, cancellation: cancellation), limit: 4096)
        } else {
          guard legacyPayload != nil else {
            throw MisoError.invalid("Missing portable Ruby compatibility probe")
          }
          data = try SafeFile.read(
            GuestVolume(cache).path(
              "resources/homebrew-sources/brew/Library/Homebrew/vendor/" + name),
            limit: 4096)
        }
      } else {
        data = try await HTTPData.get(
          URL(
            string:
              "https://raw.githubusercontent.com/Homebrew/brew/\(commit)/Library/Homebrew/vendor/\(name)"
          )!,
          maximumBytes: 4096, cancellation: cancellation)
      }
      try SafeFile.writeNew(data, to: path)
      records.append(try Artifacts.record(path, relativeTo: output))
    }
    let rubyVersion = try rubyVersion(
      SafeFile.read(output.appendingPathComponent(records[0].path), limit: 64))
    let sha = try BaseBootstrapResolution.assignment(
      "ruby_SHA", in: SafeFile.read(output.appendingPathComponent(records[1].path), limit: 4096))
    try SafeFile.validateSHA256(sha)
    let relative = "ruby-candidates/\(sha).tar.gz"
    let payload = output.appendingPathComponent(relative)
    if !FileManager.default.fileExists(atPath: payload.path) {
      guard
        try FileManager.default.contentsOfDirectory(
          atPath: payload.deletingLastPathComponent().path
        ).count < 8
      else {
        throw MisoError.unsupported(
          "Portable Ruby compatibility search exceeded eight distinct payloads; specify a Homebrew version"
        )
      }
      if let cache {
        guard let cached = previous?.payload ?? legacyPayload,
          cached.path == relative
            || (previous == nil
              && cached.path == "resources/homebrew-sources/portable-ruby.tar.gz"),
          cached.sha256 == sha, cached.bytes <= 64 << 20
        else { throw MisoError.invalid("Invalid portable Ruby probe payload") }
        try Artifacts.copy(
          Artifacts.resolve(cached, under: cache, cancellation: cancellation), to: payload,
          maximumBytes: 64 << 20, cancellation: cancellation)
      } else {
        try await HTTPFile.homebrewBlob(sha, to: payload, cancellation: cancellation)
      }
    }
    let record = try Artifacts.record(payload, relativeTo: output)
    guard record.sha256 == sha, record.bytes <= 64 << 20 else {
      throw MisoError.invalid("Portable Ruby differs from pinned Homebrew digest")
    }
    _ = try TarPayload.inspect(payload, cancellation: cancellation)
    let minimum = try BasePackageResolution.minimumMacOS(
      TarPayload.file(
        payload, path: "portable-ruby/\(rubyVersion)/bin/ruby", maximumBytes: 64 << 20,
        cancellation: cancellation))
    let result = Self(
      version: version, commit: commit, vendorVersion: records[0], vendorPlatform: records[1],
      payload: record, minimumMacOS: minimum.description)
    if let previous, previous != result {
      throw MisoError.invalid("Replayed portable Ruby compatibility changed")
    }
    try SafeFile.writeNew(
      JSON.encode(result), to: output.appendingPathComponent("compatibility/\(version)-ruby.json"))
    return result
  }

  static func rubyVersion(_ data: Data) throws -> String {
    guard data.count <= 64, let text = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid portable Ruby version")
    }
    let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try StableVersion(version)
    return version
  }
}

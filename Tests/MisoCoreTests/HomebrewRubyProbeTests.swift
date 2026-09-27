import Foundation
import Testing

@testable import MisoCore

@Test func portableRubyProbeReplaysVerifiedCompatibilityWithoutNetwork() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let cache = temporary.url.appendingPathComponent("cache")
  let output = temporary.url.appendingPathComponent("output")
  for root in [cache, output] {
    try SafeFile.makeDirectory(root)
    for name in ["compatibility", "ruby-candidates"] {
      try SafeFile.makeDirectory(root.appendingPathComponent(name))
    }
  }
  var executable = Data(count: 56)
  for (offset, value): (Int, UInt32) in [
    (0, 0xfeed_facf), (4, 0x0100_000c), (12, 2), (16, 1), (20, 24), (32, 0x32), (36, 24),
    (40, 1), (44, 26 << 16),
  ] { executable.put(value, at: offset) }
  let tar =
    tarEntry(path: "portable-ruby/4.0.7/bin/ruby", content: executable)
    + Data(count: 1024)
  let sha = SafeFile.sha256(tar)
  func write(_ path: String, _ data: Data) throws -> ImageBundle.FileRecord {
    let url = cache.appendingPathComponent(path)
    try SafeFile.writeNew(data, to: url)
    return try Artifacts.record(url, relativeTo: cache)
  }
  let commit = String(repeating: "a", count: 40)
  let probe = try HomebrewRubyProbe(
    version: "7.0.7", commit: commit,
    vendorVersion: write("compatibility/7.0.7-portable-ruby-version", Data("4.0.7\n".utf8)),
    vendorPlatform: write(
      "compatibility/7.0.7-portable-ruby-arm64-darwin", Data("ruby_SHA=\(sha)\n".utf8)),
    payload: write("ruby-candidates/\(sha).tar.gz", tar), minimumMacOS: "26.0")
  let replay = try await HomebrewRubyProbe.run(
    version: "7.0.7", commit: commit, output: output, cache: cache, previous: probe,
    legacyPayload: nil, cancellation: CancellationToken())
  #expect(replay == probe)
  #expect(try MacOSVersion(replay.minimumMacOS) > MacOSVersion("15.6.1"))
  #expect(try MacOSVersion(replay.minimumMacOS) <= MacOSVersion("26.6.2"))
  try SafeFile.replace(
    Data("4.0.8\n".utf8), at: cache.appendingPathComponent(probe.vendorVersion.path))
  #expect(throws: (any Error).self) {
    try Artifacts.resolve(probe.vendorVersion, under: cache)
  }
}

@Test func portableRubyVersionRejectsNonliteralAndOversizedValues() throws {
  #expect(try HomebrewRubyProbe.rubyVersion(Data("4.0.7\n".utf8)) == "4.0.7")
  for value in ["", "../4.0.7", "$(id)", String(repeating: "1", count: 65)] {
    #expect(throws: MisoError.self) { try HomebrewRubyProbe.rubyVersion(Data(value.utf8)) }
  }
}

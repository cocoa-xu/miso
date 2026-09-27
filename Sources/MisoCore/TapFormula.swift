import Foundation

struct TapFormula: Codable, Equatable {
  enum Profile: String, CaseIterable, Codable {
    case guestAgent = "tart-guest-agent"
    case guestLegacy = "tart-guest-agent-legacy"
    case buildkite = "buildkite-agent@3"
    case otel = "otel-cli"

    var tap: String {
      switch self {
      case .guestAgent: "openai/tools"
      case .guestLegacy: "cirruslabs/cli"
      case .buildkite: "buildkite/buildkite"
      case .otel: "equinix-labs/otel-cli"
      }
    }
    var repository: String {
      let parts = tap.split(separator: "/")
      return "\(parts[0])/homebrew-\(parts[1])"
    }
    var path: String {
      switch self {
      case .guestLegacy: "tart-guest-agent.rb"
      case .otel: "otel-cli.rb"
      default: "Formula/\(rawValue).rb"
      }
    }
    var executable: String {
      switch self {
      case .guestAgent, .guestLegacy: "tart-guest-agent"
      case .buildkite: "buildkite-agent"
      case .otel: "otel-cli"
      }
    }
    static func options(for name: String) -> [Self] {
      switch name {
      case guestAgent.rawValue: [.guestAgent, .guestLegacy]
      case buildkite.rawValue: [.buildkite]
      case otel.rawValue: [.otel]
      default: []
      }
    }
    func asset(_ version: String) -> URL {
      let repository: String
      let name: String
      switch self {
      case .guestAgent:
        repository = "openai/tart-guest-agent"
        name = "tart-guest-agent-darwin-all.tar.gz"
      case .guestLegacy:
        repository = "cirruslabs/tart-guest-agent"
        name = "tart-guest-agent-darwin-all.tar.gz"
      case .buildkite:
        repository = "buildkite/agent"
        name = "buildkite-agent-darwin-arm64-\(version).tar.gz"
      case .otel:
        repository = "equinix-labs/otel-cli"
        name = "otel-cli_\(version)_darwin_arm64.tar.gz"
      }
      return URL(string: "https://github.com/\(repository)/releases/download/v\(version)/\(name)")!
    }
  }

  let version: String
  let revision: Int
  let url: URL
  let sha256: String

  func downloadURL(profile: Profile) -> URL {
    profile == .guestLegacy ? Profile.guestAgent.asset(version) : url
  }

  init(_ data: Data, profile: Profile) throws {
    guard data.count <= 256 << 10, let text = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid tap formula source")
    }
    func matches(_ pattern: String) throws -> [[String]] {
      let expression = try NSRegularExpression(pattern: pattern)
      return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        match in
        (1..<match.numberOfRanges).map {
          Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
        }
      }
    }
    guard try matches(#"(?m)^\s*(?:depends_on|resource|bottle|patch)\b([^\n]*)"#).isEmpty else {
      throw MisoError.unsupported("Tap formula requires an unsupported dependency or build payload")
    }
    let versions = try matches(#"(?m)^\s*version\s+"([^"]+)"\s*$"#)
    let revisions = try matches(#"(?m)^\s*revision\s+([0-9]+)\s*$"#)
    guard versions.count == 1, revisions.count <= 1 else {
      throw MisoError.unsupported("Ambiguous tap formula version")
    }
    version = versions[0][0]
    _ = try StableVersion(version)
    let revision = revisions.isEmpty ? 0 : Int(revisions[0][0])
    guard let revision else { throw MisoError.invalid("Invalid tap formula revision") }
    guard (0...100_000).contains(revision) else {
      throw MisoError.invalid("Invalid tap formula revision")
    }
    self.revision = revision
    let expectedURL = profile.asset(version)
    url = expectedURL
    let assets = try matches(#"(?m)^\s*url\s+"([^"]+)"\s*\n\s*sha256\s+"([0-9a-f]{64})"\s*$"#)
      .filter { $0[0] == expectedURL.absoluteString }
    guard assets.count == 1 else {
      throw MisoError.unsupported("Missing or ambiguous macOS arm64 tap payload")
    }
    sha256 = assets[0][1]
    try SafeFile.validateSHA256(sha256)
  }

  static func minimumMacOS(_ data: Data) throws -> MacOSVersion {
    let magic = try data.integer(at: 0, as: UInt32.self, bigEndian: true)
    guard magic == 0xcafe_babe || magic == 0xcafe_babf else {
      return try BasePackageResolution.minimumMacOS(data)
    }
    let wide = magic == 0xcafe_babf
    let count = Int(try data.integer(at: 4, as: UInt32.self, bigEndian: true))
    let width = wide ? 32 : 20
    guard (1...32).contains(count), data.count >= 8 + count * width else {
      throw MisoError.invalid("Invalid universal binary architecture table")
    }
    var ranges: [Range<Int>] = []
    var arm64: Range<Int>?
    for index in 0..<count {
      let cursor = 8 + index * width
      let cpu = try data.integer(at: cursor, as: UInt32.self, bigEndian: true)
      let offset =
        try wide
        ? data.integer(at: cursor + 8, as: UInt64.self, bigEndian: true)
        : UInt64(data.integer(at: cursor + 8, as: UInt32.self, bigEndian: true))
      let size =
        try wide
        ? data.integer(at: cursor + 16, as: UInt64.self, bigEndian: true)
        : UInt64(data.integer(at: cursor + 12, as: UInt32.self, bigEndian: true))
      let alignment = try data.integer(
        at: cursor + (wide ? 24 : 16), as: UInt32.self, bigEndian: true)
      guard offset >= 8 + count * width, offset <= data.count, size > 0,
        size <= UInt64(data.count) - offset,
        alignment <= 31, offset % (UInt64(1) << alignment) == 0
      else { throw MisoError.invalid("Invalid universal binary slice bounds") }
      let range = Int(offset)..<Int(offset + size)
      guard !ranges.contains(where: { $0.overlaps(range) }) else {
        throw MisoError.invalid("Overlapping universal binary slices")
      }
      ranges.append(range)
      if cpu == 0x0100_000c {
        guard arm64 == nil else { throw MisoError.invalid("Ambiguous arm64 executable") }
        arm64 = range
      }
    }
    guard let arm64 else { throw MisoError.unsupported("Tap executable has no arm64 slice") }
    return try BasePackageResolution.minimumMacOS(
      Data(data[(data.startIndex + arm64.lowerBound)..<(data.startIndex + arm64.upperBound)]))
  }
}

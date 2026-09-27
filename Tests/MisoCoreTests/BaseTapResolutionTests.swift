import Foundation
import Testing

@testable import MisoCore

private func tapSource(_ profile: TapFormula.Profile, version: String = "1.2.3", extra: String = "")
  -> Data
{
  Data(
    """
    class Example < Formula
      version "\(version)"
      \(extra)
      url "\(profile.asset(version).absoluteString)"
      sha256 "\(String(repeating: "a", count: 64))"
    end
    """.utf8)
}

@Test func tapReleaseMetadataIsDynamicAndArchitectureBound() throws {
  for profile in TapFormula.Profile.allCases {
    let formula = try TapFormula(tapSource(profile, extra: "revision 2"), profile: profile)
    #expect(formula.version == "1.2.3")
    #expect(formula.revision == 2)
    #expect(formula.url == profile.asset("1.2.3"))
    #expect(formula.sha256 == String(repeating: "a", count: 64))
  }
}

@Test func tapReleaseMetadataRejectsAmbiguityAndUnsupportedInputs() throws {
  for extra in [
    "version \"2.0.0\"", "depends_on \"libexample\"", "resource \"extra\" do",
    "revision 999999999999999999999999999999",
  ] {
    #expect(throws: MisoError.self) {
      try TapFormula(tapSource(.otel, extra: extra), profile: .otel)
    }
  }
  let valid = String(decoding: tapSource(.otel), as: UTF8.self)
  for text in [
    valid.replacingOccurrences(of: "darwin_arm64", with: "darwin_amd64"),
    valid.replacingOccurrences(of: "github.com/", with: "github.com.evil.test/"),
    valid.replacingOccurrences(of: "version \"1.2.3\"", with: "version ENV.fetch(\"VERSION\")"),
    valid
      + "\nurl \"\(TapFormula.Profile.otel.asset("1.2.3").absoluteString)\"\nsha256 \"\(String(repeating: "a", count: 64))\"\n",
  ] {
    #expect(throws: MisoError.self) { try TapFormula(Data(text.utf8), profile: .otel) }
  }
}

@Test func tapHistoryRejectsInvalidCommitIdentity() throws {
  let sha = String(repeating: "a", count: 40)
  #expect(try BaseTapResolution.commits(Data("[{\"sha\":\"\(sha)\"}]".utf8)) == [sha])
  for bytes in [Data("{}".utf8), Data("[{\"sha\":\"../other\"}]".utf8), Data("[{}]".utf8)] {
    #expect(throws: MisoError.self) { try BaseTapResolution.commits(bytes) }
  }
}

@Test func legacyGuestAgentKeepsOriginalIdentityAndUsesTransferredRelease() throws {
  let formula = try TapFormula(tapSource(.guestLegacy, version: "0.10.0"), profile: .guestLegacy)
  #expect(formula.url.host == "github.com")
  #expect(formula.url.path.hasPrefix("/cirruslabs/tart-guest-agent/"))
  #expect(
    formula.downloadURL(profile: .guestLegacy) == TapFormula.Profile.guestAgent.asset("0.10.0"))
  #expect(TapFormula.Profile.guestLegacy.repository == "cirruslabs/homebrew-cli")
  #expect(TapFormula.Profile.guestLegacy.path == "tart-guest-agent.rb")
  #expect(TapFormula.Profile.options(for: "tart-guest-agent") == [.guestAgent, .guestLegacy])
  #expect(TapFormula.Profile.options(for: "tart-guest-agent-legacy").isEmpty)
}

@Test func tapExecutableChecksArm64SliceBoundsAndDeploymentTarget() throws {
  var thin = Data(count: 56)
  for (offset, value): (Int, UInt32) in [
    (0, 0xfeed_facf), (4, 0x0100_000c), (12, 2), (16, 1), (20, 24), (32, 0x32), (36, 24), (40, 1),
    (44, 11 << 16),
  ] {
    thin.put(value, at: offset)
  }
  #expect(try TapFormula.minimumMacOS(thin) == MacOSVersion("11.0"))
  var fat = Data()
  for value: UInt32 in [0xcafe_babe, 1, 0x0100_000c, 0, 64, 56, 6] { fat.appendGitInteger(value) }
  fat.append(Data(count: 64 - fat.count))
  fat.append(thin)
  #expect(try TapFormula.minimumMacOS(fat) == MacOSVersion("11.0"))
  #expect(try TapFormula.minimumMacOS((Data([0]) + fat).dropFirst()) == MacOSVersion("11.0"))
  fat.replaceSubrange(16..<20, with: Data([255, 255, 255, 255]))
  #expect(throws: MisoError.self) { try TapFormula.minimumMacOS(fat) }
}

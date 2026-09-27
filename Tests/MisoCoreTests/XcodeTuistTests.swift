import Foundation
import Testing

@testable import MisoCore

@Test func tuistProfilePreservesExistingConfigurationAndIsIdempotent() throws {
  let previous = Data("export EXISTING=value".utf8)
  let output = try XcodeTuistInstallation.shellProfile(previous)
  #expect(String(decoding: output, as: UTF8.self).hasPrefix("export EXISTING=value\n"))
  #expect(try XcodeTuistInstallation.shellProfile(output) == output)
  #expect(throws: MisoError.self) { try XcodeTuistInstallation.shellProfile(Data([0])) }
}

@Test func tuistFormulaBindsStableVersionPayloadAndPrerequisites() throws {
  let source = """
    class Tuist < Formula
      url "https://github.com/tuist/tuist/releases/download/4.210.0/tuist.zip"
      sha256 "\(String(repeating: "a", count: 64))"
      depends_on macos: :monterey
    end
    """
  let result = try XcodeTuistInputs.parse(Data(source.utf8), version: "4.210.0")
  #expect(result.url.lastPathComponent == "tuist.zip")
  for changed in [
    source.replacingOccurrences(of: "4.210.0", with: "4.211.0"),
    source.replacingOccurrences(of: "monterey", with: "golden_gate"),
    source.replacingOccurrences(of: "https://github.com/", with: "https://example.com/"),
    source + "\n  depends_on \"unexpected\"\n",
    source + "\n  resource \"extra\"\n",
  ] {
    #expect(throws: MisoError.self) {
      try XcodeTuistInputs.parse(Data(changed.utf8), version: "4.210.0")
    }
  }
  #expect(throws: MisoError.self) {
    try XcodeTuistInputs.parse(Data(source.utf8), version: "4.210.0-canary.1")
  }
}

import Foundation
import Testing

@testable import MisoCore

@Test func developerCaskSelectionBindsArchitectureSourceAndArtifacts() throws {
  let target = MacOSRelease(version: "27.0.1", build: "26A434")
  let url = "https://downloads.claude.ai/claude-code-releases/2.1.285/darwin-arm64/claude"
  var fields: [String: Any] = [
    "token": "claude-code", "version": "2.1.285", "disabled": false,
    "tap_git_head": String(repeating: "a", count: 40),
    "ruby_source_path": "Casks/c/claude-code.rb",
    "ruby_source_checksum": ["sha256": String(repeating: "a", count: 64)],
    "sha256": String(repeating: "b", count: 64), "url": url,
    "depends_on": [:] as [String: String],
    "artifacts": [["binary": ["claude"], "target": "$HOMEBREW_PREFIX/bin/claude"]],
    "variations": ["golden_gate": ["url": url.replacingOccurrences(of: "arm64", with: "x64")]],
  ]
  func parse(_ value: [String: Any]) throws -> XcodeCaskInputs.Cask {
    try XcodeCaskInputs.parse(
      JSONSerialization.data(withJSONObject: value), token: "claude-code", target: target)
  }
  #expect(try parse(fields).url.absoluteString == url)
  for change: [String: Any] in [
    ["disabled": true], ["url": "https://example.com/claude"],
    ["depends_on": ["formula": ["unreviewed"]]], ["depends_on": ["macos": "invalid"]],
    ["artifacts": [["pkg": ["installer.pkg"]]]],
    ["artifacts": [["binary": ["claude"], "target": "/usr/bin/claude"]]],
    ["ruby_source_path": "../claude-code.rb"],
  ] {
    var altered = fields
    altered.merge(change) { _, new in new }
    #expect(throws: MisoError.self) { try parse(altered) }
  }
  fields["variations"] = [
    "arm64_golden_gate": ["url": url.replacingOccurrences(of: "arm64", with: "x64")]
  ]
  #expect(throws: MisoError.self) { try parse(fields) }
}

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

@Test(arguments: [false, true])
func kiroCaskBindsArchiveLayoutToDeclaredArtifacts(application: Bool) throws {
  let version = application ? "2.19.0" : "3.0.0"
  let binary = application ? "$APPDIR/Kiro CLI.app/Contents/MacOS/kiro-cli" : "kirocli/bin/kiro-cli"
  let filename = application ? "Kiro%20CLI.dmg" : "kirocli-universal-darwin.zip"
  var artifacts: [[String: Any]] = [
    ["binary": [binary], "target": "$HOMEBREW_PREFIX/bin/kiro-cli"]
  ]
  if application {
    artifacts.append(["app": ["Kiro CLI.app"], "target": "/Applications/Kiro CLI.app"])
  }
  let fields: [String: Any] = [
    "token": "kiro-cli", "version": version, "disabled": false,
    "tap_git_head": String(repeating: "a", count: 40),
    "ruby_source_path": "Casks/k/kiro-cli.rb",
    "ruby_source_checksum": ["sha256": String(repeating: "a", count: 64)],
    "sha256": String(repeating: "b", count: 64),
    "url": "https://desktop-release.q.us-east-1.amazonaws.com/\(version)/\(filename)",
    "depends_on": [:] as [String: String], "artifacts": artifacts,
  ]
  func parse(_ value: [String: Any]) throws -> XcodeCaskInputs.Cask {
    try XcodeCaskInputs.parse(
      JSONSerialization.data(withJSONObject: value), token: "kiro-cli",
      target: .init(version: "27.3", build: "26C5035r"))
  }
  let cask = try parse(fields)
  #expect(cask.application == (application ? "Kiro CLI.app" : nil))
  #expect(cask.executable == (application ? "Kiro CLI.app/Contents/MacOS/kiro-cli" : binary))
  #expect(cask.filename == (application ? "payload.dmg" : "payload.zip"))
  for changed in [
    Array(artifacts.dropFirst()), artifacts + [artifacts[0]],
    [["binary": ["../kiro-cli"], "target": "$HOMEBREW_PREFIX/bin/kiro-cli"]],
    [["binary": [binary], "target": "/usr/bin/kiro-cli"]],
  ] {
    var invalid = fields
    invalid["artifacts"] = changed
    #expect(throws: MisoError.self) { try parse(invalid) }
  }
  var mixed = fields
  let other = application ? "kirocli-universal-darwin.zip" : "Kiro%20CLI.dmg"
  mixed["url"] = "https://desktop-release.q.us-east-1.amazonaws.com/\(version)/\(other)"
  #expect(throws: MisoError.self) { try parse(mixed) }
}

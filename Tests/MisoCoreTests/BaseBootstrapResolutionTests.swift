import Foundation
import Testing

@testable import MisoCore

@Test func homebrewSourceMappingsPreserveUpstreamIdentity() throws {
  var sources = BaseSourceConfiguration()
  sources.repositories["Homebrew/brew"] = "fixture/brew"
  try sources.validate()
  #expect(sources.repository("Homebrew/brew") == "fixture/brew")
  #expect(sources.repository("openai/homebrew-tools") == "openai/homebrew-tools")
  sources.repositories["other/repo"] = "fixture/repo"
  #expect(throws: MisoError.self) { try sources.validate() }
  sources.repositories = ["Homebrew/brew": "fixture/brew\n[hooks]"]
  #expect(throws: MisoError.self) { try sources.validate() }
}

@Test func homebrewCompatibilityReadsLiteralBoundsOnly() throws {
  #expect(
    try BaseBootstrapResolution.minimumMacOS(Data("HOMEBREW_MACOS_OLDEST_ALLOWED=\"11\"\n".utf8))
      == MacOSVersion("11.0"))
  #expect(
    try BaseBootstrapResolution.assignment("ruby_SHA", in: Data("ruby_SHA=abc123\n".utf8))
      == "abc123")
  for source in [
    "", "ruby_SHA=a\nruby_SHA=b\n", "ruby_SHA=$(id)", "ruby_SHA=\"unterminated", "ruby_SHA=`id`",
    "ruby_SHA=a b",
  ] {
    #expect(throws: MisoError.self) {
      try BaseBootstrapResolution.assignment("ruby_SHA", in: Data(source.utf8))
    }
  }
}

@Test func homebrewReleaseSelectionUsesStableNumericTags() throws {
  let id = String(repeating: "a", count: 40)
  let capabilities =
    try GitRemote.packet("version 2\n") + GitRemote.packet("ls-refs\n")
    + GitRemote.packet("fetch=shallow\n") + Data("0000".utf8)
  var references = Data()
  for version in ["7.0.9", "7.0.10", "8.0.0-beta.1", "7.0.8"] {
    references.append(try GitRemote.packet("\(id) refs/tags/\(version)\n"))
  }
  references.append(Data("0000".utf8))
  let remote = try GitRemote(capabilities: capabilities, references: references)
  #expect(
    try BaseBootstrapResolution.candidates(remote, requested: nil).map(\.0) == [
      "7.0.10", "7.0.9", "7.0.8",
    ])
  #expect(try BaseBootstrapResolution.candidates(remote, requested: "7.0.8").map(\.0) == ["7.0.8"])
  #expect(throws: MisoError.self) {
    try BaseBootstrapResolution.candidates(remote, requested: "7.0.7")
  }
  var cursor = try GitPack.Cursor(data: GitRemote.referenceRequest("refs/tags/"))
  #expect(try GitRemote.line(&cursor) == "command=ls-refs\n")
  #expect(try GitRemote.read(&cursor) == .delimiter)
  #expect(try GitRemote.line(&cursor) == "peel\n")
  #expect(try GitRemote.line(&cursor) == "symrefs\n")
  #expect(try GitRemote.line(&cursor) == "ref-prefix refs/tags/\n")
  #expect(try GitRemote.line(&cursor) == nil)
}

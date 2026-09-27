import Foundation
import Testing

@testable import MisoCore

@Test func runtimeVersionsComeFromLiteralTargetMetadata() throws {
  let header =
    "#define NODE_MAJOR_VERSION 24\n#define NODE_MINOR_VERSION 21\n#define NODE_PATCH_VERSION 0\n"
  #expect(try BaseRuntimeInputs.nodeVersion(Data(header.utf8)) == "24.21.0")
  for invalid in [header + "#define NODE_MAJOR_VERSION 25\n", "#define NODE_MAJOR_VERSION (24)\n"] {
    #expect(throws: MisoError.self) { try BaseRuntimeInputs.nodeVersion(Data(invalid.utf8)) }
  }
  let manifest = Data(
    #"{"name":"npm","version":"11.19.0","engines":{"node":"^20.17.0 || >=22.9.0"}}"#.utf8)
  #expect(try BaseRuntimeInputs.npmVersion(manifest, node: "24.21.0") == "11.19.0")
  #expect(throws: MisoError.self) { try BaseRuntimeInputs.npmVersion(manifest, node: "18.0.0") }
  for quote in ["\"", "'"] {
    let source = "module Gem\n  VERSION = \(quote)4.0.20\(quote)\nend\n"
    #expect(try BaseRuntimeInputs.rubyGemsVersion(Data(source.utf8)) == "4.0.20")
    #expect(throws: MisoError.self) {
      try BaseRuntimeInputs.rubyGemsVersion(Data((source + source).utf8))
    }
  }
  for invalid in [
    "module Other\n  VERSION = \"4.0.20\"\nend\n",
    "module Gem\n  VERSION = discover_version\nend\n",
    "module Gem\n  VERSION = \"4.0.20\" + suffix\nend\n",
    "module Gem\n  VERSION = '4.0.20\"\nend\n",
  ] {
    #expect(throws: MisoError.self) { try BaseRuntimeInputs.rubyGemsVersion(Data(invalid.utf8)) }
  }
}

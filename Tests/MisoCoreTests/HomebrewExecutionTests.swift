import Foundation
import Testing

@testable import MisoCore

@Test func homebrewRubyCommandKeepsOnePreloadAndSeparatesScriptArguments() {
  let program = "require 'json'; puts ARGV.fetch(0)"
  let prefix = ["ruby", "-r", "/private/tmp/isolation.rb", "-e", program]
  #expect(
    HomebrewExecution.rubyArguments(adapter: "/private/tmp/isolation.rb", program: program)
      == prefix)
  #expect(
    HomebrewExecution.rubyArguments(
      adapter: "/private/tmp/isolation.rb", program: program, arguments: ["-rjson"])
      == prefix + ["--", "-rjson"])
}

@Test func homebrewInstallArgumentsRemainDataInRubyAdapter() throws {
  let arguments = ["--skip-post-install", "/tmp/a'#{abort 'injected'}.tar.gz"]
  let program = try HomebrewExecution.installProgram(arguments: arguments)
  #expect(!program.contains("#{"))
  let encoded = try JSON.encode(arguments).base64EncodedString()
  #expect(program.contains("JSON.parse('\(encoded)'.unpack1('m0'))"))
  #expect(
    try JSONDecoder().decode([String].self, from: #require(Data(base64Encoded: encoded)))
      == arguments)
  for invalid in [[], ["bad\0argument"], [String(repeating: "a", count: 4097)]] {
    #expect(throws: MisoError.self) { try HomebrewExecution.installProgram(arguments: invalid) }
  }
}

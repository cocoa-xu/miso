import Foundation
import Testing

@testable import MisoCore

@Test func homebrewKernelGroupsDoNotRequireRubyDirectoryServiceLookup() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let script = temporary.url.appendingPathComponent("groups.rb")
  let program = """
    original_identity = [Process.uid, Process.euid, Process.gid, Process.egid]
    def Process.groups; raise Errno::EINVAL; end
    \(HomebrewExecution.groupsProgram)
    Process.singleton_class.define_method(:groups, &kernel_groups)
    raise 'Primary group absent' unless Process.groups.include?(Process.egid)
    raise 'Group list is mutable across calls' if Process.groups.clear == Process.groups
    raise 'Identity changed' unless [Process.uid, Process.euid, Process.gid, Process.egid] == original_identity
    puts 'kernel groups available'
    """
  try SafeFile.writeNew(Data(program.utf8), to: script)
  let output = try SafeFile.create(temporary.url.appendingPathComponent("stdout"))
  let error = try SafeFile.create(temporary.url.appendingPathComponent("stderr"))
  defer {
    try? output.close()
    try? error.close()
  }
  let result = try NativeProcess.run(
    NativeCommand("/usr/bin/ruby", arguments: [script.path], timeout: 15),
    stdout: output, stderr: error)
  #expect(result.succeeded)
}

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
  for invalid in [[], ["bad\0argument"], [String(repeating: "a", count: 4097)]] {
    #expect(throws: MisoError.self) { try HomebrewExecution.installProgram(arguments: invalid) }
  }
}

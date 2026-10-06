import Darwin
import Foundation

final class HomebrewExecution {
  private let guest: GuestExecution
  private let root: URL
  private let identity: stat
  private let path: String

  init(guest: GuestExecution) throws {
    self.guest = guest
    let directory = "private/tmp/miso-brew-" + UUID().uuidString
    root = try guest.data.path(directory)
    path = "/" + directory + "/isolation.rb"
    try SafeFile.makeDirectory(root, mode: 0o755)
    identity = try FileMetadata.inspect(root)
    do {
      guard identity.st_uid == 0 else {
        throw MisoError.invalid("Homebrew adapter must be root-owned")
      }
      let file = root.appendingPathComponent("isolation.rb")
      try SafeFile.writeNew(
        Data(try Self.program(uid: guest.account.uid, gid: guest.account.gid).utf8), to: file)
      guard chmod(file.path, 0o444) == 0 else {
        throw MisoError.system("Protect Homebrew execution adapter", errno)
      }
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  func remove() throws {
    let current = try FileMetadata.inspect(root)
    guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
      current.st_mode & S_IFMT == S_IFDIR, current.st_uid == 0
    else {
      throw MisoError.invalid("Homebrew adapter directory identity changed")
    }
    try FileManager.default.removeItem(at: root)
  }

  func rubyArguments(program: String, arguments: [String] = []) -> [String] {
    Self.rubyArguments(adapter: path, program: program, arguments: arguments)
  }

  static func rubyArguments(adapter: String, program: String, arguments: [String] = []) -> [String]
  {
    ["ruby", "-r", adapter, "-e", program] + (arguments.isEmpty ? [] : ["--"] + arguments)
  }

  func verify() throws {
    let child =
      "require 'sandbox'; require 'socket'; raise 'Nested sandbox enabled' if Sandbox.available?; raise 'Child groups differ' unless [[], [Process.egid]].include?(Process.groups); raise 'Wrong ARM cellar' unless Utils::Bottles.tag.default_cellar == '/opt/homebrew/Cellar'; begin; TCPServer.new('127.0.0.1',0); abort 'IP socket unexpectedly allowed'; rescue Errno::EPERM,Errno::EACCES; puts 'IP denied'; end"
    let encoded = try JSON.encode(child).base64EncodedString()
    let control = """
      require 'json'
      command = JSON.parse('\(encoded)'.unpack1('m0'))
      output = IO.popen([*HOMEBREW_RUBY_EXEC_ARGS, '-I', $LOAD_PATH.join(File::PATH_SEPARATOR), '-e', command], &:read)
      raise 'Child isolation control failed' unless $?.success?
      print output
      """
    guard
      try guest.run(
        "homebrew-child-isolation",
        arguments: GuestExecution.brewArguments(
          rubyArguments(program: control), username: guest.account.username),
        capability: .brew) == "IP denied"
    else {
      throw MisoError.invalid("Homebrew child execution isolation differs")
    }
  }

  static func installProgram(arguments: [String]) throws -> String {
    guard !arguments.isEmpty, arguments.count <= 256,
      arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 })
    else {
      throw MisoError.invalid("Invalid Homebrew install arguments")
    }
    let encoded = try JSON.encode(arguments).base64EncodedString()
    return """
      require 'json'; require 'cmd/install'
      Homebrew::Cmd::InstallCmd.new(JSON.parse('\(encoded)'.unpack1('m0'))).run
      exit(Homebrew.failed? ? 1 : 0)
      """
  }

  static func program(uid: UInt32, gid: UInt32, propagate: Bool = true) throws -> String {
    guard (501...60_000).contains(uid), (20...60_000).contains(gid) else {
      throw MisoError.invalid("Invalid Homebrew execution identity")
    }
    return """
      require 'global'; require 'sandbox'; require 'fiddle'
      \(groupsProgram)
      native = Fiddle.dlopen(nil)
      check = Fiddle::Function.new(native['sandbox_check'], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      ids = kernel_groups.call
      raise 'Missing outer isolation' unless Process.euid == \(uid) && [[], [\(gid)]].include?(ids) && check.call(Process.pid, nil, 0) == 1
      Process.singleton_class.define_method(:groups, &kernel_groups)
      \(prefixProgram)
      Sandbox.singleton_class.prepend(Module.new { def available?; false; end })
      \(propagate ? """
      args = HOMEBREW_RUBY_EXEC_ARGS.dup
      args.concat(['-r', __FILE__])
      Object.send(:remove_const, :HOMEBREW_RUBY_EXEC_ARGS)
      Object.const_set(:HOMEBREW_RUBY_EXEC_ARGS, args.freeze)
      """ : "")
      """
  }

  static let groupsProgram = """
    require 'fiddle'
    query_groups = Fiddle::Function.new(Fiddle.dlopen(nil)['getgroups'], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
    kernel_groups = lambda do
      buffer = Fiddle::Pointer.malloc(128)
      count = query_groups.call(32, buffer)
      raise 'Cannot read kernel groups' unless (0..32).cover?(count)
      buffer[0, count * 4].unpack('I*')
    end
    """

  static let prefixProgram = """
    require 'utils/bottles'
    prefix = Homebrew::DEFAULT_PREFIX
    raise 'Unexpected ARM Homebrew prefix' unless prefix == '/opt/homebrew' && HOMEBREW_PREFIX.to_s == prefix && RUBY_PLATFORM.start_with?('arm64-')
    if HOMEBREW_MACOS_ARM_DEFAULT_PREFIX.nil?
      raise 'Unexpected missing ARM cellar' unless Homebrew::DEFAULT_MACOS_ARM_CELLAR == '/Cellar'
      Object.send(:remove_const, :HOMEBREW_MACOS_ARM_DEFAULT_PREFIX)
      Object.const_set(:HOMEBREW_MACOS_ARM_DEFAULT_PREFIX, prefix.freeze)
      Homebrew.send(:remove_const, :DEFAULT_MACOS_ARM_CELLAR)
      Homebrew.const_set(:DEFAULT_MACOS_ARM_CELLAR, "#{prefix}/Cellar".freeze)
    end
    raise 'ARM Homebrew prefix differs' unless HOMEBREW_MACOS_ARM_DEFAULT_PREFIX == prefix && Utils::Bottles.tag.default_cellar == "#{prefix}/Cellar"
    ENV['HOMEBREW_MACOS_ARM_DEFAULT_PREFIX'] = prefix
    """
}

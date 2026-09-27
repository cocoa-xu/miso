import Darwin
import Foundation

public enum BaseTaps {
  public struct Details: Codable {
    let plan: BaseTapInputs.Plan
    let planSHA256: String
    let installed: [String: String]
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
  }

  public static func run(
    source: URL, plan planURL: URL, inputs: URL, output: URL,
    username: String = "admin", cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planSHA256 = try SafeFile.sha256(planURL)
    let plan = try BaseTapInputs.verify(plan: planURL, inputs: inputs, cancellation: cancellation)
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-taps", cancellation: cancellation
    ) {
      bundle, target, journal in
      guard target == plan.target else {
        throw MisoError.invalid("Tap plan target differs from image")
      }
      try journal.setMetadata("tapPlan", value: plan)
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      let paths = ["opt/homebrew", "Users/\(username)/.homebrew"]
      var identity: [UInt32] = []
      var installed: [String: String] = [:]
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        identity = [guest.account.uid, guest.account.gid]
        try guest.verifyControls(target: target)
        func brew(
          _ name: String, _ arguments: [String], capability: GuestExecution.Capability = .base,
          timeout: TimeInterval = 90
        ) throws -> String {
          try guest.run(
            name, arguments: GuestExecution.brewArguments(arguments, username: username),
            capability: capability, timeout: timeout)
        }
        let adapterDirectory = "private/tmp/miso-brew-" + UUID().uuidString
        let adapterRoot = try guest.data.path(adapterDirectory)
        try SafeFile.makeDirectory(adapterRoot, mode: 0o755)
        let adapterPath = "/" + adapterDirectory + "/isolation.rb"
        let adapter = adapterRoot.appendingPathComponent("isolation.rb")
        try SafeFile.writeNew(
          Data(try isolationProgram(uid: guest.account.uid, gid: guest.account.gid).utf8),
          to: adapter)
        guard chmod(adapter.path, 0o444) == 0 else {
          throw MisoError.system("Protect Homebrew execution adapter", errno)
        }
        defer { try? FileManager.default.removeItem(at: adapterRoot) }
        let childControl =
          "require 'sandbox'; require 'socket'; raise 'Nested sandbox enabled' if Sandbox.available?; "
          + networkControl
        let controlLiteral = String(decoding: try JSON.encode(childControl), as: UTF8.self)
        let control = """
          output = IO.popen([*HOMEBREW_RUBY_EXEC_ARGS, '-I', $LOAD_PATH.join(File::PATH_SEPARATOR), '-e', \(controlLiteral)], &:read)
          raise 'Child isolation control failed' unless $?.success?
          print output
          """
        guard
          try brew(
            "tap-child-isolation", ["ruby", "-r", adapterPath, "-e", control], capability: .brew)
            == "IP denied"
        else {
          throw MisoError.invalid("Homebrew child execution isolation differs")
        }
        guard
          try brew(
            "tap-network-denial", ["ruby", "-rsocket", "-e", networkControl], capability: .brew)
            == "IP denied"
        else {
          throw MisoError.invalid("Tap execution permits IP sockets")
        }
        let before = try BaseBottles.installedVersions(
          brew("tap-list-before", ["list", "--formula", "--versions"]))
        var expected = before
        for tap in plan.taps {
          let origin = try BaseTapInputs.tree(tap, inputs: inputs)
          let inventory = try BaseInputArchive.inventory(origin, cancellation: journal.cancellation)
          let parent = String(tap.destination[..<tap.destination.lastIndex(of: "/")!])
          try directory(parent, guest: guest)
          let destination = try guest.data.path(tap.destination)
          guard !(try guest.data.contains(tap.destination)) else {
            throw MisoError.invalid("Tap destination already exists: \(tap.name)")
          }
          try BaseFileTree.copy(
            origin, to: destination, entries: inventory, uid: guest.account.uid,
            gid: guest.account.gid, cancellation: journal.cancellation)
          let git = [
            "/usr/bin/env", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
            "/Library/Developer/CommandLineTools/usr/bin/git", "--no-optional-locks", "-c",
            "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null", "-C", "/" + tap.destination,
          ]
          guard
            try guest.run("tap-revision", arguments: git + ["rev-parse", "HEAD"]) == tap.revision,
            try guest.run(
              "tap-clean", arguments: git + ["status", "--porcelain", "--untracked-files=all"]
            ).isEmpty
          else { throw MisoError.invalid("Tap revision or working tree differs from plan") }
        }
        try directory("Users/\(username)/.homebrew", guest: guest)
        try directory("Users/\(username)/Library/Caches/Homebrew/downloads", guest: guest)
        for tap in plan.taps {
          for formula in tap.formulas {
            guard expected[formula.name] == nil else {
              throw MisoError.invalid("Tap formula already installed: \(formula.name)")
            }
            let fullName = tap.name + "/" + formula.name
            _ = try brew("tap-trust", ["trust", "--formula", fullName])
            let cached = try brew("tap-cache", ["--cache", fullName])
            let relative = try cachePath(cached, username: username)
            guard !(try guest.data.contains(relative)) else {
              throw MisoError.invalid("Tap cache destination already exists")
            }
            let origin = try Artifacts.resolve(
              formula.payload, under: inputs, cancellation: journal.cancellation)
            let destination = try guest.data.path(relative)
            try Artifacts.copy(
              origin, to: destination, maximumBytes: formula.payload.bytes,
              cancellation: journal.cancellation)
            guard try SafeFile.sha256(destination) == formula.payload.sha256,
              chown(destination.path, guest.account.uid, guest.account.gid) == 0,
              chmod(destination.path, 0o444) == 0
            else { throw MisoError.invalid("Staged tap payload differs from plan") }
            _ = try brew(
              "tap-install",
              [
                "ruby", "-r", adapterPath, "-e",
                installProgram(fullName: fullName, uid: guest.account.uid, gid: guest.account.gid),
              ], capability: .brew, timeout: 300)
            expected[formula.name] = formula.kegVersion
          }
        }
        installed = try BaseBottles.installedVersions(
          brew("tap-list-after", ["list", "--formula", "--versions"]))
        guard installed == expected else {
          throw MisoError.invalid("Installed tap formula versions differ from plan")
        }
        let inventory = try Dictionary(
          uniqueKeysWithValues: paths.map { path in
            let inventory = try BaseFileTree.inventory(
              guest.data, path: path, cancellation: journal.cancellation)
            try BaseFileTree.requireOwnership(
              guest.data.path(path), entries: inventory, uid: guest.account.uid,
              gid: guest.account.gid)
            return (path, inventory)
          })
        try FileManager.default.removeItem(at: adapterRoot)
        return inventory
      }
      try SafeFile.writeNew(
        JSON.encode(payload), to: output.appendingPathComponent("tap-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let container = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          container.volume(role: "Data"), session: session, journal: journal, name: "tap-audit",
          readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == identity else {
          throw MisoError.invalid("Tap account identity changed")
        }
        for path in paths {
          guard let inventory = payload[path],
            try BaseFileTree.inventory(data, path: path, cancellation: journal.cancellation)
              == inventory
          else { throw MisoError.invalid("Detached tap payload verification failed") }
          try BaseFileTree.requireOwnership(
            data.path(path), entries: inventory, uid: account.uid, gid: account.gid)
        }
      }
      _ = try BaseTapInputs.verify(
        plan: planURL, inputs: inputs, cancellation: journal.cancellation)
      guard try SafeFile.sha256(planURL) == planSHA256 else {
        throw MisoError.invalid("Tap plan changed")
      }
      return Details(
        plan: plan, planSHA256: planSHA256, installed: installed,
        payloadEntries: payload.values.reduce(0) { $0 + $1.count },
        detachedPayloadVerified: true, executionControlsVerified: true)
    }
  }

  private static func directory(_ relative: String, guest: GuestExecution) throws {
    let url = try guest.data.path(relative)
    if !(try guest.data.contains(relative)) { try SafeFile.makeDirectory(url) }
    _ = try guest.data.directory(relative)
    guard chown(url.path, guest.account.uid, guest.account.gid) == 0, chmod(url.path, 0o755) == 0
    else {
      throw MisoError.system("Set tap directory ownership", errno)
    }
  }

  static func cachePath(_ value: String, username: String) throws -> String {
    guard username.range(of: #"\A[a-z][a-z0-9_-]{0,30}\z"#, options: .regularExpression) != nil,
      value.range(
        of:
          "\\A/Users/\(username)/Library/Caches/Homebrew/downloads/[0-9a-f]{64}--[A-Za-z0-9_.+-]+\\z",
        options: .regularExpression) != nil
    else { throw MisoError.invalid("Unexpected tap cache location") }
    return String(value.dropFirst())
  }

  private static let networkControl =
    #"begin; TCPServer.new('127.0.0.1',0); abort 'IP socket unexpectedly allowed'; rescue Errno::EPERM,Errno::EACCES; puts 'IP denied'; end"#

  static func installProgram(fullName: String, uid: UInt32, gid: UInt32) throws -> String {
    let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, (501...60_000).contains(uid), (20...60_000).contains(gid),
      parts.prefix(2).allSatisfy({
        $0.range(of: #"\A[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil
      })
    else { throw MisoError.invalid("Invalid tap execution identity") }
    try PackageRequest(name: String(parts[2])).validate()
    return """
      \(try isolationProgram(uid: uid, gid: gid, propagate: false))
      require 'cmd/install'
      Homebrew::Cmd::InstallCmd.new(['\(fullName)']).run
      exit(Homebrew.failed? ? 1 : 0)
      """
  }

  static func isolationProgram(uid: UInt32, gid: UInt32, propagate: Bool = true) throws -> String {
    guard (501...60_000).contains(uid), (20...60_000).contains(gid) else {
      throw MisoError.invalid("Invalid Homebrew execution identity")
    }
    return """
      require 'global'; require 'sandbox'; require 'fiddle'
      native = Fiddle.dlopen(nil)
      check = Fiddle::Function.new(native['sandbox_check'], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      groups = Fiddle::Function.new(native['getgroups'], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
      buffer = Fiddle::Pointer.malloc(128)
      count = groups.call(32, buffer)
      ids = count < 0 ? nil : buffer[0, count * 4].unpack('I*')
      raise 'Missing outer isolation' unless Process.euid == \(uid) && [[], [\(gid)]].include?(ids) && check.call(Process.pid, nil, 0) == 1
      Sandbox.singleton_class.prepend(Module.new { def available?; false; end })
      \(propagate ? """
      args = HOMEBREW_RUBY_EXEC_ARGS.dup
      args.concat(['-r', __FILE__])
      Object.send(:remove_const, :HOMEBREW_RUBY_EXEC_ARGS)
      Object.const_set(:HOMEBREW_RUBY_EXEC_ARGS, args.freeze)
      """ : "")
      """
  }
}

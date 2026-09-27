import Darwin
import Foundation

public enum BaseRuby {
  public struct Plan: Codable {
    public let schemaVersion: Int
    public let target: MacOSRelease
    public let builds: [Build]
    public let defaultVersion: String
    public let jobs: Int

    func validate() throws {
      _ = try RestoreProfile.select(target)
      guard schemaVersion == 1, (1...8).contains(jobs), (1...8).contains(builds.count),
        Set(builds.map(\.version)).count == builds.count,
        builds.contains(where: { $0.version == defaultVersion })
      else { throw MisoError.invalid("Invalid Ruby build plan") }
      for build in builds { try build.validate() }
    }
  }

  public struct Build: Codable {
    public let version: String
    public let opensslFormula: String?
    public let sources: [ImageBundle.FileRecord]

    func validate() throws {
      _ = try StableVersion(version)
      guard version.split(separator: ".").count == 3,
        sources.first?.path == "ruby-\(version).tar.gz",
        Set(sources.map(\.path)).count == sources.count,
        sources.allSatisfy({ $0.bytes > 0 && $0.bytes <= 256 << 20 })
      else { throw MisoError.invalid("Invalid Ruby source inputs") }
      if let opensslFormula {
        guard sources.count == 1,
          opensslFormula.range(
            of: #"\Aopenssl(@[0-9]+(\.[0-9]+)*)?\z"#,
            options: .regularExpression) != nil
        else { throw MisoError.invalid("Invalid Ruby OpenSSL formula") }
      } else {
        guard sources.count == 2,
          sources[1].path.range(
            of: #"\Aopenssl-[0-9]+\.[0-9]+\.[0-9]+[a-z]?\.tar\.gz\z"#,
            options: .regularExpression) != nil
        else { throw MisoError.invalid("Vendored OpenSSL requires a local source archive") }
      }
      for source in sources { try SafeFile.validateSHA256(source.sha256) }
    }
  }

  struct Toolchain: Equatable {
    let deployment: String
    let triplet: String
    let clangTarget: String

    init(_ target: MacOSRelease) throws {
      _ = try RestoreProfile.select(target)
      deployment = "\(try MacOSVersion(target.version).major).0"
      let darwin = target.build.prefix(while: \.isNumber)
      guard !darwin.isEmpty else { throw MisoError.invalid("Missing target Darwin version") }
      triplet = "aarch64-apple-darwin" + darwin
      clangTarget = "arm64-apple-macos" + deployment
    }
  }

  public struct Probe: Codable {
    let version: String
    let platform: String
    let host: String
    let openssl: String
    let psych: String
    let zlib: String
  }

  public struct Details: Codable {
    let plan: Plan
    let planSHA256: String
    let probes: [Probe]
    let definitionSHA256: [String: String]
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
    let systemCertificateTrustVerified: Bool
  }

  public static func verify(
    plan: URL, inputs: URL, cancellation: CancellationToken? = nil
  ) throws -> Plan {
    let result = try JSON.read(Plan.self, from: plan)
    try result.validate()
    for build in result.builds {
      for source in build.sources {
        _ = try Artifacts.resolve(source, under: inputs, cancellation: cancellation)
      }
    }
    return result
  }

  public static func run(
    source: URL, plan planURL: URL, inputs: URL, output: URL,
    username: String = "admin", cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planSHA256 = try SafeFile.sha256(planURL)
    let plan = try verify(plan: planURL, inputs: inputs, cancellation: cancellation)
    let toolchain = try Toolchain(plan.target)
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-ruby", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == plan.target else {
        throw MisoError.invalid("Ruby plan target differs from image")
      }
      try journal.setMetadata("rubyPlan", value: plan)
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      let rbenv = "Users/\(username)/.rbenv"
      var probes: [Probe] = []
      var definitions: [String: String] = [:]
      var identity: [UInt32] = []
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        identity = [guest.account.uid, guest.account.gid]
        try guest.verifyControls(target: target)
        for relative in [
          rbenv, rbenv + "/versions", rbenv + "/shims", "opt/homebrew/var/ruby-cache",
        ] {
          let path = try guest.data.path(relative)
          if !(try guest.data.contains(relative)) { try SafeFile.makeDirectory(path) }
          _ = try guest.data.directory(relative)
          guard chown(path.path, guest.account.uid, guest.account.gid) == 0,
            chmod(path.path, 0o755) == 0
          else { throw MisoError.system("Set Ruby directory ownership", errno) }
        }
        try controls(guest, rbenv: rbenv)
        let sdk = try guest.run("ruby-sdk", arguments: ["/usr/bin/xcrun", "--show-sdk-path"])
        guard sdk.hasPrefix("/Library/Developer/CommandLineTools/SDKs/"),
          sdk.range(of: #"\A/[A-Za-z0-9/._-]+\.sdk\z"#, options: .regularExpression) != nil
        else { throw MisoError.invalid("Unexpected target SDK path") }
        let environment = environment(guest: guest, sdk: sdk, toolchain: toolchain, jobs: plan.jobs)
        let compile =
          #"printf '#include <stdio.h>\nint main(void){puts("offline-target");return 0;}\n' > /private/tmp/miso-compile.c && $CC /private/tmp/miso-compile.c -o /private/tmp/miso-compile && /private/tmp/miso-compile && /bin/rm /private/tmp/miso-compile.c /private/tmp/miso-compile"#
        guard
          try guest.run(
            "ruby-compile-control", arguments: environment + ["/bin/sh", "-c", compile],
            capability: .ruby) == "offline-target"
        else { throw MisoError.invalid("Target compiler control failed") }
        for build in plan.builds {
          guard !(try guest.data.contains(rbenv + "/versions/" + build.version)) else {
            throw MisoError.invalid("Requested Ruby is already installed")
          }
          let definition = try guest.run(
            "ruby-build-definition",
            arguments: [
              "/bin/cat", "/opt/homebrew/share/ruby-build/" + build.version,
            ])
          for archive in build.sources {
            guard definition.contains(archive.sha256) else {
              throw MisoError.invalid("Ruby build definition differs from source digest")
            }
            let origin = try Artifacts.resolve(
              archive, under: inputs, cancellation: journal.cancellation)
            let relative = "opt/homebrew/var/ruby-cache/" + archive.path
            if try guest.data.contains(relative) {
              guard try SafeFile.sha256(guest.data.path(relative)) == archive.sha256 else {
                throw MisoError.invalid("Ruby source cache conflicts with plan")
              }
            } else {
              let destination = try guest.data.path(relative)
              try Artifacts.copy(
                origin, to: destination, maximumBytes: archive.bytes,
                cancellation: journal.cancellation)
              guard try SafeFile.sha256(destination) == archive.sha256,
                chown(destination.path, guest.account.uid, guest.account.gid) == 0,
                chmod(destination.path, 0o444) == 0
              else { throw MisoError.invalid("Staged Ruby source differs from input") }
            }
          }
          let record = output.appendingPathComponent("ruby-definition-" + build.version + ".txt")
          try SafeFile.writeNew(Data(definition.utf8), to: record)
          definitions[build.version] = try SafeFile.sha256(record)
          var configure =
            "--build=\(toolchain.triplet) --host=\(toolchain.triplet) --disable-install-doc --with-libyaml-dir=/opt/homebrew/opt/libyaml"
          var options: [String] = []
          if let formula = build.opensslFormula {
            configure +=
              " --with-openssl-dir=/opt/homebrew/opt/\(formula) --with-baseruby=/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"
          } else {
            options.append("RUBY_BUILD_VENDOR_OPENSSL=1")
          }
          options.append("RUBY_CONFIGURE_OPTS=" + configure)
          try journal.measure("rubyBuild-" + build.version + "Seconds") {
            try guest.run(
              "ruby-build",
              arguments: environment + options + [
                "/opt/homebrew/bin/rbenv", "install", "-v", build.version,
              ], capability: .ruby, timeout: 1800)
          }
          let probe = try guest.run(
            "ruby-extensions",
            arguments: [
              "/" + rbenv + "/versions/" + build.version + "/bin/ruby", "-e", probeProgram,
            ], capability: .ruby)
          probes.append(try validateProbe(probe, build: build, toolchain: toolchain))
        }
        try guest.run(
          "ruby-global",
          arguments: environment + [
            "/opt/homebrew/bin/rbenv", "global", plan.defaultVersion,
          ], capability: .ruby)
        try guest.run(
          "ruby-rehash", arguments: environment + ["/opt/homebrew/bin/rbenv", "rehash"],
          capability: .ruby)
        guard
          try guest.run(
            "ruby-default",
            arguments: environment + [
              "/" + rbenv + "/shims/ruby", "-e", "print RUBY_VERSION",
            ], capability: .ruby) == plan.defaultVersion
        else { throw MisoError.invalid("Default Ruby shim differs from plan") }
        let entries = try BaseFileTree.inventory(
          guest.data, path: rbenv, cancellation: journal.cancellation)
        try BaseFileTree.requireOwnership(
          guest.data.path(rbenv), entries: entries,
          uid: guest.account.uid, gid: guest.account.gid)
        return entries
      }
      try SafeFile.writeNew(
        JSON.encode(payload), to: output.appendingPathComponent("ruby-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let container = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          container.volume(role: "Data"), session: session,
          journal: journal, name: "ruby-audit", readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == identity,
          try BaseFileTree.inventory(data, path: rbenv, cancellation: journal.cancellation)
            == payload
        else { throw MisoError.invalid("Detached Ruby payload verification failed") }
        try BaseFileTree.requireOwnership(
          data.path(rbenv), entries: payload, uid: account.uid, gid: account.gid)
      }
      _ = try verify(plan: planURL, inputs: inputs, cancellation: journal.cancellation)
      guard try SafeFile.sha256(planURL) == planSHA256 else {
        throw MisoError.invalid("Ruby plan changed")
      }
      return Details(
        plan: plan, planSHA256: planSHA256, probes: probes,
        definitionSHA256: definitions, payloadEntries: payload.count,
        detachedPayloadVerified: true, executionControlsVerified: true,
        systemCertificateTrustVerified: false)
    }
  }

  private static func environment(
    guest: GuestExecution, sdk: String, toolchain: Toolchain, jobs: Int
  ) -> [String] {
    let home = "/Users/" + guest.account.username
    return [
      "/usr/bin/env", "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_INSTALL_FROM_API=1",
      "HOMEBREW_NO_BOOTSNAP=1", "HOMEBREW_CACHE=\(home)/Library/Caches/Homebrew",
      "HOMEBREW_LOGS=\(home)/Library/Caches/Homebrew/Logs", "HOMEBREW_TEMP=/private/tmp",
      "DEVELOPER_DIR=/Library/Developer/CommandLineTools", "SDKROOT=" + sdk,
      "MACOSX_DEPLOYMENT_TARGET=" + toolchain.deployment, "MAKE_OPTS=-j\(jobs)",
      "CC=/Library/Developer/CommandLineTools/usr/bin/clang -target " + toolchain.clangTarget,
      "CXX=/Library/Developer/CommandLineTools/usr/bin/clang++ -target " + toolchain.clangTarget,
      "RBENV_ROOT=\(home)/.rbenv", "RUBY_BUILD_CACHE_PATH=/opt/homebrew/var/ruby-cache",
      "RUBY_BUILD_SKIP_MIRROR=1",
    ]
  }

  private static func controls(_ guest: GuestExecution, rbenv: String) throws {
    try guest.run(
      "ruby-write-control",
      arguments: [
        "/bin/sh", "-c", "printf allowed > /\(rbenv)/.miso-control",
      ], capability: .ruby)
    try guest.run(
      "ruby-write-denial",
      arguments: [
        "/bin/sh", "-c", "printf forbidden > /Users/\(guest.account.username)/.miso-outside",
      ], capability: .ruby, expectedExitCodes: [1])
    try guest.run(
      "ruby-fd-denial",
      arguments: [
        "/bin/sh", "-c",
        "exec 9< /Users/\(guest.account.username)/.zprofile; printf forbidden > /dev/fd/9",
      ], capability: .ruby, expectedExitCodes: [1])
    try FileManager.default.removeItem(at: guest.data.path(rbenv + "/.miso-control"))
  }

  static let probeProgram =
    #"require 'json'; require 'openssl'; require 'psych'; require 'zlib'; require 'rbconfig'; puts JSON.generate(version: RUBY_VERSION, platform: RUBY_PLATFORM, host: RbConfig::CONFIG['host'], openssl: OpenSSL::OPENSSL_VERSION, psych: Psych::LIBYAML_VERSION, zlib: Zlib::ZLIB_VERSION)"#

  static func validateProbe(_ text: String, build: Build, toolchain: Toolchain) throws -> Probe {
    let probe = try JSONDecoder().decode(Probe.self, from: Data(text.utf8))
    guard probe.version == build.version, probe.host == toolchain.triplet,
      probe.platform == toolchain.triplet.replacingOccurrences(of: "-apple", with: "")
        || probe.platform
          == toolchain.triplet.replacingOccurrences(of: "aarch64-apple", with: "arm64"),
      !probe.openssl.isEmpty, !probe.psych.isEmpty, !probe.zlib.isEmpty
    else { throw MisoError.invalid("Ruby probe differs from target build plan") }
    return probe
  }
}

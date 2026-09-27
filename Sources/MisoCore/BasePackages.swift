import Darwin
import Foundation

public enum BasePackages {
  public struct Details: Codable {
    let plan: BasePackageInputs.Plan
    let planSHA256: String
    let installed: [String: String]
    let probes: [String: String]
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
  }

  public static func run(
    source: URL, plan planURL: URL, inputs: URL, output: URL,
    username: String = "admin", cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planSHA256 = try SafeFile.sha256(planURL)
    let plan = try BasePackageInputs.verify(
      plan: planURL, inputs: inputs, cancellation: cancellation)
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-packages", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == plan.target else {
        throw MisoError.invalid("Package plan target differs from image")
      }
      try journal.setMetadata("packagePlan", value: plan)
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      let rbenv = "Users/\(username)/.rbenv"
      let paths = ["opt/homebrew", rbenv]
      var installed: [String: String] = [:]
      var probes: [String: String] = [:]
      var identity: [UInt32] = []
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        identity = [guest.account.uid, guest.account.gid]
        try guest.verifyControls(target: target)
        let relative = "Users/\(username)/.miso-packages-" + UUID().uuidString
        let staging = try guest.data.path(relative)
        try SafeFile.makeDirectory(staging)
        guard chmod(staging.path, 0o755) == 0 else {
          throw MisoError.system("Set package staging permissions", errno)
        }
        let stagingIdentity = try FileMetadata.inspect(staging)
        var archives: [String] = []
        for (index, package) in ([plan.bundler] + plan.npm).enumerated() {
          let origin = try Artifacts.resolve(
            package.payload, under: inputs, cancellation: journal.cancellation)
          let filename = "\(index)-" + origin.lastPathComponent
          let destination = staging.appendingPathComponent(filename)
          try Artifacts.copy(
            origin, to: destination, maximumBytes: package.payload.bytes,
            cancellation: journal.cancellation)
          guard try SafeFile.sha256(destination) == package.payload.sha256,
            chmod(destination.path, 0o444) == 0
          else { throw MisoError.invalid("Staged package differs from input") }
          archives.append("/" + relative + "/" + filename)
        }
        let rubyBin = "/\(rbenv)/versions/\(plan.rubyVersion)/bin"
        let rubyEnvironment = [
          "/usr/bin/env", "PATH=\(rubyBin):/opt/homebrew/bin:/usr/bin:/bin", "RBENV_ROOT=/" + rbenv,
        ]
        guard
          try guest.run(
            "package-ruby-version", arguments: [rubyBin + "/ruby", "-e", "print RUBY_VERSION"])
            == plan.rubyVersion
        else { throw MisoError.invalid("Package target Ruby differs from plan") }
        if let runtimes = plan.runtimes {
          let node = "/opt/homebrew/opt/" + plan.nodeFormula + "/bin"
          let environment = ["/usr/bin/env", "PATH=\(node):/usr/bin:/bin"]
          let actual = try BasePackageInputs.Runtimes(
            node: guest.run(
              "package-node-version", arguments: [node + "/node", "-p", "process.versions.node"]),
            npm: guest.run(
              "package-npm-version", arguments: environment + [node + "/npm", "--version"]),
            rubygems: guest.run(
              "package-rubygems-version",
              arguments: [rubyBin + "/ruby", "-rrubygems", "-e", "print Gem::VERSION"]))
          guard actual == runtimes else {
            throw MisoError.invalid("Package resolver runtimes differ from the target image")
          }
        }
        try guest.run(
          "bundler-install",
          arguments: rubyEnvironment + [
            rubyBin + "/gem", "install", "--local", archives[0], "--no-document",
          ], capability: .ruby, timeout: 300)
        try guest.run(
          "packages-rehash", arguments: rubyEnvironment + ["/opt/homebrew/bin/rbenv", "rehash"],
          capability: .ruby)
        let bundler = try guest.run(
          "bundler-version",
          arguments: rubyEnvironment + [
            "/" + rbenv + "/shims/bundle", "--version",
          ], capability: .ruby)
        try journal.setMetadata(
          "bundlerVersionProbe",
          value: [
            "expected": plan.bundler.version, "actual": String(bundler.prefix(1024)),
          ])
        _ = try bundlerVersion(bundler, expected: plan.bundler.version)
        probes["bundler"] = bundler
        let nodeBin = "/opt/homebrew/opt/" + plan.nodeFormula + "/bin"
        let environment = [
          "/usr/bin/env", "PATH=\(nodeBin):/opt/homebrew/bin:/usr/bin:/bin",
          "npm_config_cache=/Users/\(username)/Library/Caches/npm",
          "npm_config_prefix=/opt/homebrew", "npm_config_audit=false", "npm_config_fund=false",
          "npm_config_offline=true", "npm_config_engine_strict=true", "COREPACK_ENABLE_NETWORK=0",
        ]
        func versions(_ name: String) throws -> [String: String] {
          try installedVersions(
            guest.run(
              name,
              arguments: environment + [
                nodeBin + "/npm", "ls", "--global", "--json", "--depth=0",
              ], capability: .base))
        }
        var expected = try versions("npm-before")
        for package in plan.npm { expected[package.name] = package.version }
        try guest.run(
          "npm-install",
          arguments: environment + [
            nodeBin + "/npm", "install", "--global", "--offline", "--omit=optional",
            "--foreground-scripts",
          ] + archives.dropFirst(), capability: .base, timeout: 300)
        installed = try versions("npm-after")
        guard installed == expected else {
          throw MisoError.invalid("Installed npm versions differ from plan")
        }
        for package in plan.npm where ["yarn", "pnpm"].contains(package.name) {
          let executable = "/opt/homebrew/bin/" + package.name
          let version = try guest.run(
            "package-manager-version", arguments: environment + [executable, "--version"],
            capability: .base)
          guard version == package.version else {
            throw MisoError.invalid("Package manager probe differs from plan")
          }
          probes[package.name] = version
          let project = "private/tmp/miso-package-control-" + UUID().uuidString
          let directory = try guest.data.path(project)
          try SafeFile.makeDirectory(directory)
          guard chown(directory.path, guest.account.uid, guest.account.gid) == 0,
            chmod(directory.path, 0o755) == 0
          else { throw MisoError.system("Set package control ownership", errno) }
          let directoryIdentity = try FileMetadata.inspect(directory)
          try guest.data.write(
            project + "/package.json",
            data: Data(#"{"name":"miso-offline-control","version":"1.0.0","private":true}"#.utf8),
            uid: guest.account.uid, gid: guest.account.gid)
          try guest.run(
            "package-manager-offline-control",
            arguments: environment + [
              "/bin/sh", "-c", #"cd "$1" && exec "$2" install --offline --ignore-scripts"#,
              "package-control", "/" + project, executable,
            ], capability: .base)
          try removeOwnedDirectory(
            directory, identity: directoryIdentity, data: guest.data, relative: project)
        }
        try removeOwnedDirectory(
          staging, identity: stagingIdentity, data: guest.data, relative: relative)
        return try Dictionary(
          uniqueKeysWithValues: paths.map { path in
            let inventory = try BaseFileTree.inventory(
              guest.data, path: path, cancellation: journal.cancellation)
            try BaseFileTree.requireOwnership(
              guest.data.path(path), entries: inventory,
              uid: guest.account.uid, gid: guest.account.gid)
            return (path, inventory)
          })
      }
      try SafeFile.writeNew(
        JSON.encode(payload), to: output.appendingPathComponent("package-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let container = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          container.volume(role: "Data"), session: session,
          journal: journal, name: "package-audit", readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == identity else {
          throw MisoError.invalid("Package account changed")
        }
        for path in paths {
          guard let inventory = payload[path],
            try BaseFileTree.inventory(data, path: path, cancellation: journal.cancellation)
              == inventory
          else { throw MisoError.invalid("Detached package payload verification failed") }
          try BaseFileTree.requireOwnership(
            data.path(path), entries: inventory, uid: account.uid, gid: account.gid)
        }
      }
      _ = try BasePackageInputs.verify(
        plan: planURL, inputs: inputs, cancellation: journal.cancellation)
      guard try SafeFile.sha256(planURL) == planSHA256 else {
        throw MisoError.invalid("Package plan changed")
      }
      return Details(
        plan: plan, planSHA256: planSHA256, installed: installed, probes: probes,
        payloadEntries: payload.values.reduce(0) { $0 + $1.count },
        detachedPayloadVerified: true, executionControlsVerified: true)
    }
  }

  private static func removeOwnedDirectory(
    _ url: URL, identity: stat, data: GuestVolume, relative: String
  ) throws {
    let current = try FileMetadata.inspect(data.path(relative))
    guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
      current.st_mode & S_IFMT == S_IFDIR
    else { throw MisoError.invalid("Package directory identity changed") }
    try FileManager.default.removeItem(at: url)
  }

  static func installedVersions(_ text: String) throws -> [String: String] {
    struct Listing: Decodable {
      struct Dependency: Decodable { let version: String }
      let dependencies: [String: Dependency]?
      let problems: [String]?
    }
    let listing = try JSONDecoder().decode(Listing.self, from: Data(text.utf8))
    guard listing.problems?.isEmpty ?? true else {
      throw MisoError.invalid("npm reported dependency problems")
    }
    return (listing.dependencies ?? [:]).mapValues(\.version)
  }

  static func bundlerVersion(_ text: String, expected: String) throws -> String {
    _ = try StableVersion(expected)
    let actual = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard [expected, "Bundler version " + expected].contains(actual) else {
      throw MisoError.invalid(
        "Bundler version mismatch: expected \(expected), received \(String(reflecting: String(actual.prefix(256))))"
      )
    }
    return expected
  }
}

import Darwin
import Foundation

public enum XcodeGemInstallation {
  public struct Details: Encodable {
    let plan: XcodeGemInputs.Plan
    let planSHA256: String
    let probes: [String: String]
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
  }

  public static func install(
    source: URL, prepared: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planURL = prepared.appendingPathComponent("plan.json")
    let hash = try SafeFile.sha256(planURL)
    let plan = try XcodeGemInputs.verify(prepared, cancellation: cancellation)
    return try BaseImageStage.run(
      source: source, output: output, operation: "xcode-gems", layer: .xcode,
      cancellation: cancellation
    ) { bundle, target, journal in
      let image = bundle.appendingPathComponent("disk.img")
      let view = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      let rbenv = "Users/\(username)/.rbenv"
      var probes: [String: String] = [:]
      var identity: [UInt32] = []
      let inventory = try GuestExecution.withSession(
        image: image, root: view, username: username, journal: journal
      ) { guest in
        try guest.verifyControls(target: target)
        identity = [guest.account.uid, guest.account.gid]
        let configuration = XcodeConfiguration()
        _ = try XcodeArchive.inspect(
          guest.data.directory(configuration.applicationPath).url,
          target: target, configuration: configuration)
        let bin = "/" + rbenv + "/versions/" + plan.rubyVersion + "/bin"
        let sdk = try guest.run(
          "gem-sdk-path",
          arguments: [
            "/usr/bin/env", "DEVELOPER_DIR=/Library/Developer/CommandLineTools",
            "/usr/bin/xcrun", "--show-sdk-path",
          ])
        guard sdk.hasPrefix("/Library/Developer/CommandLineTools/SDKs/"),
          sdk.range(of: #"\A/[A-Za-z0-9/._-]+\.sdk\z"#, options: .regularExpression) != nil
        else { throw MisoError.invalid("Gem compiler SDK is unavailable") }
        let environment = [
          "/usr/bin/env", "PATH=\(bin):/opt/homebrew/bin:/usr/bin:/bin",
          "DEVELOPER_DIR=/Library/Developer/CommandLineTools", "SDKROOT=" + sdk,
          "RBENV_ROOT=/" + rbenv, "LANG=en_US.UTF-8",
          "FASTLANE_SKIP_UPDATE_CHECK=1", "FASTLANE_OPT_OUT_USAGE=1", "FASTLANE_HIDE_CHANGELOG=1",
        ]
        guard
          try guest.run("gem-ruby-version", arguments: [bin + "/ruby", "-e", "print RUBY_VERSION"])
            == plan.rubyVersion,
          try guest.run(
            "gem-rubygems-version",
            arguments: [bin + "/ruby", "-rrubygems", "-e", "print Gem::VERSION"])
            == plan.rubygemsVersion
        else { throw MisoError.invalid("Gem runtime differs from prepared inputs") }
        let relative = "Users/\(username)/.miso-gems-" + UUID().uuidString
        let staging = try guest.data.path(relative)
        try SafeFile.makeDirectory(staging, mode: 0o755)
        let stagingIdentity = try FileMetadata.inspect(staging)
        var arguments: [String] = []
        for package in plan.packages {
          let original = try Artifacts.resolve(
            package.payload, under: prepared, cancellation: journal.cancellation)
          let name = package.name + "-" + package.version + ".gem"
          let destination = staging.appendingPathComponent(name)
          try Artifacts.copy(
            original, to: destination, maximumBytes: package.payload.bytes,
            cancellation: journal.cancellation)
          guard try SafeFile.sha256(destination) == package.payload.sha256,
            chmod(destination.path, 0o444) == 0
          else { throw MisoError.invalid("Staged gem differs from input") }
          arguments.append("./" + name)
        }
        try guest.run(
          "gems-install",
          arguments: environment + [
            "/bin/sh", "-c", #"cd "$1" && shift && exec "$@""#, "gem-install", "/" + relative,
            bin + "/gem", "install", "--local", "--no-document", "--env-shebang",
          ] + arguments, capability: .ruby, timeout: 1800)
        try guest.run(
          "gems-rehash", arguments: environment + ["/opt/homebrew/bin/rbenv", "rehash"],
          capability: .ruby)
        let versions = Dictionary(uniqueKeysWithValues: plan.packages.map { ($0.name, $0.version) })
        let expected = String(decoding: try JSON.encode(versions), as: UTF8.self)
        probes["dependencies"] = try guest.run(
          "gems-dependency-control",
          arguments: environment + [
            bin + "/ruby", "-rjson", "-rrubygems", "-e", dependencyControl, expected,
          ],
          capability: .ruby)
        for (name, executable) in [
          ("cocoapods", "pod"), ("fastlane", "fastlane"), ("xcpretty", "xcpretty"),
        ] {
          let result = try guest.run(
            "gem-version", arguments: environment + [bin + "/" + executable, "--version"],
            capability: .ruby, timeout: 180)
          guard result.contains(versions[name]!) else {
            throw MisoError.invalid("Installed gem version probe differs: \(name)")
          }
          probes[name] = result
        }
        let current = try FileMetadata.inspect(guest.data.path(relative))
        guard current.st_dev == stagingIdentity.st_dev, current.st_ino == stagingIdentity.st_ino,
          current.st_mode & S_IFMT == S_IFDIR
        else { throw MisoError.invalid("Gem staging identity changed") }
        try FileManager.default.removeItem(at: staging)
        let inventory = try BaseFileTree.inventory(
          guest.data, path: rbenv, cancellation: journal.cancellation)
        try BaseFileTree.requireOwnership(
          guest.data.path(rbenv), entries: inventory, uid: guest.account.uid, gid: guest.account.gid
        )
        return inventory
      }
      try SafeFile.writeNew(
        JSON.encode(inventory), to: output.appendingPathComponent("gem-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let data = try ImageMounts.mount(
          BaseImageStage.mainContainer(session).volume(role: "Data"), session: session,
          journal: journal, name: "gem-audit", readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == identity,
          try BaseFileTree.inventory(data, path: rbenv, cancellation: journal.cancellation)
            == inventory
        else { throw MisoError.invalid("Detached gem payload or account differs") }
        try BaseFileTree.requireOwnership(
          data.path(rbenv), entries: inventory, uid: account.uid, gid: account.gid)
      }
      _ = try XcodeGemInputs.verify(prepared, cancellation: journal.cancellation)
      guard try SafeFile.sha256(planURL) == hash else {
        throw MisoError.invalid("Gem plan changed")
      }
      return Details(
        plan: plan, planSHA256: hash, probes: probes, payloadEntries: inventory.count,
        detachedPayloadVerified: true, executionControlsVerified: true)
    }
  }

  static let dependencyControl = """
    expected = JSON.parse(ARGV.fetch(0))
    expected.each do |name, version|
      spec = Gem::Specification.find_by_name(name, "= " + version)
      spec.runtime_dependencies.each do |dependency|
        selected = expected.fetch(dependency.name)
        abort "Unsatisfied gem dependency" unless dependency.requirement.satisfied_by?(Gem::Version.new(selected))
      end
    end
    puts JSON.generate(expected.sort.to_h)
    """
}

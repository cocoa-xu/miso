import Darwin
import Foundation

public enum XcodeHomebrew {
  public struct Details: Codable {
    public let version: String
    public let brewRevision: String
    public let coreRevision: String
    public let portableRubyVersion: String
    public let installedFormulaePreserved: Bool
  }

  public static func install(
    source: URL, prepared: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let receipt = try JSON.read(
      BaseBootstrapResolution.Receipt.self, from: prepared.appendingPathComponent("resolution.json")
    )
    let archive = try BaseInputArchive.verify(prepared, cancellation: cancellation)
    guard archive.archiveSHA256 == receipt.archiveSHA256 else {
      throw MisoError.invalid("Homebrew refresh archive differs from its resolution")
    }
    let inputs = prepared.appendingPathComponent("resources/homebrew-sources")
    let ruby = try JSON.read(
      BaseBootstrap.PortableRuby.self, from: inputs.appendingPathComponent("portable-ruby.json"))
    _ = try StableVersion(ruby.version)
    let tar = inputs.appendingPathComponent("portable-ruby.tar.gz")
    let entries = try TarPayload.inspect(tar, cancellation: cancellation)
    let rubyPrefix = "portable-ruby/" + ruby.version
    guard entries.allSatisfy({ $0.path == rubyPrefix || $0.path.hasPrefix(rubyPrefix + "/") }),
      entries.contains(where: { $0.path == rubyPrefix + "/bin/ruby" && $0.kind == S_IFREG })
    else { throw MisoError.invalid("Unexpected portable Ruby refresh layout") }
    return try BaseImageStage.run(
      source: source, output: output, operation: "xcode-homebrew", layer: .xcode,
      cancellation: cancellation
    ) { bundle, target, journal in
      guard target == receipt.target else {
        throw MisoError.invalid("Homebrew refresh target differs from the image")
      }
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      return try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        try guest.verifyControls(target: target)
        func brew(_ name: String, _ arguments: [String]) throws -> String {
          try guest.run(
            name, arguments: GuestExecution.brewArguments(arguments, username: username),
            capability: .base)
        }
        let before = try BaseBottles.installedVersions(
          brew("homebrew-formulae-before", ["list", "--formula", "--versions"]))
        let relative = "private/tmp/miso-homebrew-refresh-" + UUID().uuidString
        try guest.data.makeDirectories(relative, uid: guest.account.uid, gid: guest.account.gid)
        let staging = try guest.data.directory(relative).url
        defer { try? FileManager.default.removeItem(at: staging) }
        for name in ["brew", "core"] {
          let origin = inputs.appendingPathComponent(name)
          try BaseFileTree.copy(
            origin, to: staging.appendingPathComponent(name),
            entries: BaseInputArchive.inventory(origin, cancellation: journal.cancellation),
            uid: guest.account.uid, gid: guest.account.gid, cancellation: journal.cancellation)
        }
        try update(
          guest: guest, repository: "/opt/homebrew", staging: "/" + relative + "/brew",
          selection: receipt.brew.selection, name: "brew")
        try update(
          guest: guest, repository: "/opt/homebrew/Library/Taps/homebrew/homebrew-core",
          staging: "/" + relative + "/core", selection: receipt.core.selection, name: "core")
        let vendor = try guest.data.directory("opt/homebrew/Library/Homebrew/vendor").url
        let required = try String(
          decoding: SafeFile.read(
            vendor.appendingPathComponent("portable-ruby-version"), limit: 64),
          as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard required == ruby.version else {
          throw MisoError.invalid("Updated Homebrew requires a different portable Ruby")
        }
        let rubyStage = staging.appendingPathComponent("ruby")
        try SafeFile.makeDirectory(rubyStage)
        try TarPayload.extract(
          tar, into: rubyStage, entries: entries, uid: guest.account.uid, gid: guest.account.gid,
          cancellation: journal.cancellation)
        let portable = vendor.appendingPathComponent("portable-ruby")
        let version = portable.appendingPathComponent(ruby.version)
        if FileManager.default.fileExists(atPath: version.path) {
          _ = try GuestVolume(version)
          try FileManager.default.removeItem(at: version)
        }
        try FileManager.default.moveItem(
          at: rubyStage.appendingPathComponent(rubyPrefix), to: version)
        let current = portable.appendingPathComponent("current")
        guard try FileMetadata.inspect(current).st_mode & S_IFMT == S_IFLNK,
          unlink(current.path) == 0, symlink(ruby.version, current.path) == 0,
          lchown(current.path, guest.account.uid, guest.account.gid) == 0
        else { throw MisoError.invalid("Cannot update the portable Ruby selection") }
        let versionOutput = try brew("homebrew-version", ["--version"])
        guard versionOutput.split(separator: "\n").first == "Homebrew " + receipt.version,
          try guest.run(
            "homebrew-ruby-version",
            arguments: [
              "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby",
              "-e", "print RUBY_VERSION",
            ]) == ruby.version,
          try BaseBottles.installedVersions(
            brew("homebrew-formulae-after", ["list", "--formula", "--versions"])) == before
        else {
          throw MisoError.invalid("Homebrew refresh changed installed formulae or tool versions")
        }
        return Details(
          version: receipt.version, brewRevision: receipt.brew.selection.commitID,
          coreRevision: receipt.core.selection.commitID, portableRubyVersion: ruby.version,
          installedFormulaePreserved: true)
      }
    }
  }

  static func gitArguments(repository: String) -> [String] {
    [
      "/usr/bin/env", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
      "/Library/Developer/CommandLineTools/usr/bin/git", "--no-optional-locks",
      "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
      "-c", "protocol.allow=never", "-c", "protocol.file.allow=always", "-C", repository,
    ]
  }

  private static func update(
    guest: GuestExecution, repository: String, staging: String,
    selection: GitRemote.Selection, name: String
  ) throws {
    let git = gitArguments(repository: repository)
    guard
      try guest.run(
        "homebrew-\(name)-clean-before",
        arguments: git + ["status", "--porcelain", "--untracked-files=no"]
      ).isEmpty
    else { throw MisoError.invalid("Homebrew \(name) has modified tracked files") }
    var references = [selection.commitID]
    if selection.reference.hasPrefix("refs/tags/") {
      references.append(selection.reference + ":" + selection.reference)
    }
    try guest.run(
      "homebrew-\(name)-fetch",
      arguments: git + [
        "fetch", "--no-tags", "--update-shallow", "--no-recurse-submodules", staging,
      ]
        + references,
      capability: .base, timeout: 120,
      progress: "Refresh Homebrew \(name) from prepared local sources")
    try guest.run(
      "homebrew-\(name)-checkout", arguments: git + ["checkout", "--detach", selection.commitID],
      capability: .base, timeout: 120)
    guard
      try guest.run("homebrew-\(name)-revision", arguments: git + ["rev-parse", "HEAD"])
        == selection.commitID,
      try guest.run(
        "homebrew-\(name)-clean-after",
        arguments: git + ["status", "--porcelain", "--untracked-files=no"]
      ).isEmpty
    else { throw MisoError.invalid("Updated Homebrew \(name) differs from prepared sources") }
  }
}

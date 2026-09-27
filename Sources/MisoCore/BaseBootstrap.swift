import Darwin
import Foundation

public enum BaseBootstrap {
  struct PortableRuby: Decodable {
    let version: String
    let sha256: String
    let bytes: UInt64
  }

  public struct Details: Codable {
    public let archiveSHA256: String
    public let homebrewVersion: String
    public let portableRubyVersion: String
    public let inputEntries: Int
    public let payloadEntries: Int
    public let detachedPayloadVerified: Bool
    public let executionControlsVerified: Bool
    public let packagesInstalled: Bool
  }

  public static func run(
    source: URL, archive: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let archiveURL = archive.appendingPathComponent("archive.json")
    let archiveSHA256 = try SafeFile.sha256(archiveURL)
    let manifest = try JSON.read(BaseInputArchive.Manifest.self, from: archiveURL)
    let snapshots = manifest.resources.filter { $0.name == "homebrew-sources" }
    guard manifest.schemaVersion == 1, snapshots.count == 1 else {
      throw MisoError.invalid("Missing Homebrew input snapshot")
    }
    let inputs = archive.appendingPathComponent("resources/homebrew-sources")
    let inventory = try BaseInputArchive.inventory(inputs, cancellation: cancellation)
    guard inventory == snapshots[0].entries else {
      throw MisoError.invalid("Homebrew archive resource differs from snapshot")
    }
    func subtree(_ path: String) throws -> [BaseInputArchive.Entry] {
      let result = inventory.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map {
        BaseInputArchive.Entry(
          path: $0.path == path ? "." : String($0.path.dropFirst(path.count + 1)),
          kind: $0.kind, mode: $0.mode, bytes: $0.bytes, sha256: $0.sha256, link: $0.link)
      }
      guard result.first?.path == ".", result.first?.kind == "directory" else {
        throw MisoError.invalid("Missing Homebrew source directory")
      }
      return result
    }
    let brew = try subtree("brew")
    let core = try subtree("core")
    let ruby = try JSON.read(
      PortableRuby.self, from: inputs.appendingPathComponent("portable-ruby.json"))
    _ = try StableVersion(ruby.version)
    try SafeFile.validateSHA256(ruby.sha256)
    let rubyTar = inputs.appendingPathComponent("portable-ruby.tar.gz")
    guard try SafeFile.sha256(rubyTar) == ruby.sha256,
      UInt64(try FileMetadata.inspect(rubyTar).st_size) == ruby.bytes
    else { throw MisoError.invalid("Portable Ruby archive mismatch") }
    let entries = try TarPayload.inspect(rubyTar, cancellation: cancellation)
    let rubyPrefix = "portable-ruby/" + ruby.version
    guard entries.allSatisfy({ $0.path == rubyPrefix || $0.path.hasPrefix(rubyPrefix + "/") }),
      entries.contains(where: {
        $0.path == rubyPrefix + "/bin/ruby" && $0.kind == S_IFREG && $0.mode & 0o111 != 0
      })
    else {
      throw MisoError.invalid("Unexpected portable Ruby layout")
    }
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-bootstrap", cancellation: cancellation
    ) { bundle, target, journal in
      try journal.setMetadata("inputArchiveSHA256", value: archiveSHA256)
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      var homebrewVersion = ""
      var portableRubyVersion = ""
      var accountIdentity: [UInt32] = []
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        let data = guest.data
        let account = guest.account
        accountIdentity = [account.uid, account.gid]
        let prefix = try data.path("opt/homebrew", createParents: true)
        try BaseFileTree.copy(
          inputs.appendingPathComponent("brew"), to: prefix, entries: brew,
          uid: account.uid, gid: account.gid, cancellation: journal.cancellation)
        let tap = try data.path(
          "opt/homebrew/Library/Taps/homebrew/homebrew-core", createParents: true)
        try BaseFileTree.copy(
          inputs.appendingPathComponent("core"), to: tap, entries: core,
          uid: account.uid, gid: account.gid, cancellation: journal.cancellation)
        for relative in ["opt/homebrew/Library/Taps", "opt/homebrew/Library/Taps/homebrew"] {
          guard chown(try data.path(relative).path, account.uid, account.gid) == 0 else {
            throw MisoError.system("Set tap ownership", errno)
          }
        }
        let vendor = try data.path("opt/homebrew/Library/Homebrew/vendor")
        let requiredVersion = try String(
          data: SafeFile.read(vendor.appendingPathComponent("portable-ruby-version"), limit: 64),
          encoding: .utf8)
        guard requiredVersion?.trimmingCharacters(in: .whitespacesAndNewlines) == ruby.version
        else { throw MisoError.invalid("Portable Ruby version differs from Homebrew requirement") }
        let staging = vendor.appendingPathComponent(".miso-portable-stage")
        try SafeFile.makeDirectory(staging)
        try TarPayload.extract(
          rubyTar, into: staging, entries: entries, uid: account.uid, gid: account.gid,
          cancellation: journal.cancellation)
        let portable = vendor.appendingPathComponent("portable-ruby")
        guard !FileManager.default.fileExists(atPath: portable.path),
          rename(staging.appendingPathComponent("portable-ruby").path, portable.path) == 0,
          rmdir(staging.path) == 0,
          symlink(ruby.version, portable.appendingPathComponent("current").path) == 0,
          lchown(portable.appendingPathComponent("current").path, account.uid, account.gid) == 0
        else { throw MisoError.system("Publish portable Ruby", errno) }
        for relative in [
          "opt/homebrew/Cellar", "opt/homebrew/Caskroom", "opt/homebrew/etc", "opt/homebrew/var",
          "opt/homebrew/var/homebrew", "opt/homebrew/var/homebrew/locks",
          "opt/homebrew/var/homebrew/cache",
          "Users/\(username)/Library/Caches/Homebrew",
          "Users/\(username)/Library/Caches/Homebrew/Logs",
        ] {
          let path = try data.path(relative, createParents: true)
          if !(try data.contains(relative)) { try SafeFile.makeDirectory(path) }
          guard chown(path.path, account.uid, account.gid) == 0 else {
            throw MisoError.system("Set Homebrew directory ownership", errno)
          }
        }
        try guest.verifyControls(target: target)
        portableRubyVersion = try guest.run(
          "portable-ruby-version",
          arguments: [
            "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby", "-e",
            "print RUBY_VERSION",
          ])
        guard portableRubyVersion == ruby.version else {
          throw MisoError.invalid("Executed portable Ruby version mismatch")
        }
        try guest.run(
          "guest-network-denial",
          arguments: [
            "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby", "-rsocket",
            "-e",
            "begin; TCPSocket.new('127.0.0.1', 9); exit 2; rescue Errno::EPERM, Errno::EACCES; puts 'network-denied'; end",
          ])
        homebrewVersion = try guest.run(
          "homebrew-version",
          arguments: GuestExecution.brewArguments(["--version"], username: username),
          capability: .base)
        guard homebrewVersion.hasPrefix("Homebrew ") else {
          throw MisoError.invalid("Unexpected Homebrew version output")
        }
        let inventory = try BaseInputArchive.inventory(prefix, cancellation: journal.cancellation)
        try requireOwnership(prefix, entries: inventory, account: account)
        return inventory
      }
      try SafeFile.writeNew(
        JSON.encode(payload), to: output.appendingPathComponent("bootstrap-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let main = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "bootstrap-audit",
          readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == accountIdentity else {
          throw MisoError.invalid("Target account changed during bootstrap")
        }
        guard
          try BaseInputArchive.inventory(
            data.path("opt/homebrew"), cancellation: journal.cancellation) == payload
        else {
          throw MisoError.invalid("Detached Homebrew payload verification failed")
        }
        try requireOwnership(data.path("opt/homebrew"), entries: payload, account: account)
      }
      guard try SafeFile.sha256(archiveURL) == archiveSHA256,
        try BaseInputArchive.inventory(inputs, cancellation: journal.cancellation) == inventory
      else {
        throw MisoError.invalid("Homebrew inputs changed during installation")
      }
      return Details(
        archiveSHA256: archiveSHA256, homebrewVersion: homebrewVersion,
        portableRubyVersion: portableRubyVersion, inputEntries: inventory.count,
        payloadEntries: payload.count, detachedPayloadVerified: true,
        executionControlsVerified: true, packagesInstalled: false)
    }
  }
  private static func requireOwnership(
    _ root: URL, entries: [BaseInputArchive.Entry], account: BaseImageStage.Account
  ) throws {
    for entry in entries {
      let path = entry.path == "." ? root : root.appendingPathComponent(entry.path)
      let info = try FileMetadata.inspect(path)
      guard info.st_uid == account.uid, info.st_gid == account.gid else {
        throw MisoError.invalid("Homebrew payload ownership mismatch: \(entry.path)")
      }
    }
  }
}

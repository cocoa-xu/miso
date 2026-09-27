import Darwin
import Foundation

public enum BaseStaticLayer {
  struct RunnerRelease: Decodable {
    struct Asset: Decodable {
      let name: String
      let size: UInt64
      let digest: String
    }
    let tagName: String
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case assets
    }
  }

  struct PayloadEntry: Codable, Equatable {
    let path: String
    let uid: UInt32
    let gid: UInt32
    let mode: UInt16
    let bytes: UInt64?
    let sha256: String?
    let link: String?
  }

  public struct Receipt: Codable, Sendable {
    public let target: MacOSRelease
    public let sourceManifest: ImageBundle.FileRecord
    public let files: [ImageBundle.FileRecord]
    public let runnerVersion: String
    public let payloadEntries: Int
    public let originalsUnchanged: Bool
    public let staticPayloadVerified: Bool
    public let baseComplete: Bool
    public let runtimeVerified: Bool
  }

  public static func run(
    source: URL, runner: URL, release: URL, knownHosts: URL, output: URL,
    username: String = "admin", nodeFormula: String = "node@24",
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Base construction requires administrator privileges")
    }
    guard username.range(of: #"\A[a-z][a-z0-9_-]{0,30}\z"#, options: .regularExpression) != nil
    else {
      throw MisoError.invalid("Invalid target account name")
    }
    try PackageRequest(name: nodeFormula).validate()
    _ = try APFSPrivate.requireHost()
    _ = try GuestVolume(source)
    let sourceManifest = try Artifacts.record(
      source.appendingPathComponent("manifest.json"), relativeTo: source)
    let manifestData = try SafeFile.read(
      source.appendingPathComponent("manifest.json"), limit: 1 << 20)
    guard var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
      manifest["construction_vm_started"] as? Bool == false,
      manifest["runtime_verified"] as? Bool == false,
      let target = manifest["target"] as? [String: String],
      let version = target["version"], let build = target["build"]
    else { throw MisoError.invalid("A never-booted native source bundle is required") }
    let profile = try RestoreProfile.select(MacOSRelease(version: version, build: build))
    let original = try ImageBundle.verify(source)
    let runnerRelease = try JSON.read(RunnerRelease.self, from: release)
    let runnerDigest = try SafeFile.sha256(runner)
    let matching = runnerRelease.assets.filter { $0.name == runner.lastPathComponent }
    guard matching.count == 1, let asset = matching.first,
      runner.lastPathComponent
        == "actions-runner-osx-arm64-\(runnerRelease.tagName.dropFirst()).tar.gz",
      runnerRelease.tagName.hasPrefix("v"), asset.digest == "sha256:" + runnerDigest,
      asset.size == UInt64(try FileMetadata.inspect(runner).st_size)
    else { throw MisoError.invalid("Runner release asset identity or digest mismatch") }
    _ = try StableVersion(String(runnerRelease.tagName.dropFirst()))
    let entries = try TarPayload.inspect(runner, cancellation: cancellation)
    for path in ["run.sh", "bin/Runner.Listener"] {
      guard
        entries.contains(where: { $0.path == path && $0.kind == S_IFREG && $0.mode & 0o111 != 0 })
      else {
        throw MisoError.invalid("Missing runner executable: \(path)")
      }
    }
    let hosts = try SafeFile.read(knownHosts, limit: 64 << 10)
    guard let hostsText = String(data: hosts, encoding: .utf8), !hostsText.isEmpty,
      !hostsText.contains("\0"),
      hostsText.split(separator: "\n").allSatisfy({ $0.hasPrefix("github.com ") })
    else { throw MisoError.invalid("Expected GitHub known-host entries") }
    let journal = try ExecutionJournal(
      output: output, operation: "base-static", cancellation: cancellation)
    return try journal.perform {
      try journal.setMetadata("target", value: profile.release)
      try journal.setMetadata("runnerSHA256", value: runnerDigest)
      try journal.setMetadata("releaseSHA256", value: SafeFile.sha256(release))
      try journal.setMetadata("knownHostsSHA256", value: SafeFile.sha256(hosts))
      let sourceSession = try DiskImageSession(
        image: source.appendingPathComponent("disk.img"), readOnly: true, journal: journal)
      try sourceSession.requireDetached()
      let bundle = journal.output.appendingPathComponent("bundle")
      try SafeFile.makeDirectory(bundle)
      for name in ImageBundle.requiredFiles.sorted() {
        try Artifacts.clone(
          source.appendingPathComponent(name), to: bundle.appendingPathComponent(name))
      }
      try verifySystem(
        image: bundle.appendingPathComponent("disk.img"), target: profile.release, journal: journal)
      let session = try DiskImageSession(
        image: bundle.appendingPathComponent("disk.img"), readOnly: false, journal: journal)
      var containerID: UUID?
      var dataID: UUID?
      var paths: [String] = []
      let written = try session.withAttachment { session -> [PayloadEntry] in
        let main = try mainContainer(session)
        containerID = main.identifier
        dataID = try main.volume(role: "Data").identifier
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "data",
          readOnly: false)
        paths = try install(
          data: data, username: username, nodeFormula: nodeFormula,
          runner: runner, entries: entries, knownHosts: hosts, cancellation: journal.cancellation)
        guard try SafeFile.sha256(runner) == runnerDigest else {
          throw MisoError.invalid("Runner archive changed")
        }
        return try inventory(data: data, paths: paths, cancellation: journal.cancellation)
      }
      try SafeFile.writeNew(
        JSON.encode(written), to: journal.output.appendingPathComponent("payload.json"))
      let audit = try DiskImageSession(image: session.image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let main = try mainContainer(session)
        guard main.identifier == containerID, try main.volume(role: "Data").identifier == dataID
        else {
          throw MisoError.invalid("Base volume identity changed during reattachment")
        }
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "audit-data",
          readOnly: true)
        guard try inventory(data: data, paths: paths, cancellation: journal.cancellation) == written
        else {
          throw MisoError.invalid("Detached read-only Base payload audit failed")
        }
      }
      try sourceSession.requireDetached()
      guard try ImageBundle.verify(source).files == original.files,
        try Artifacts.record(source.appendingPathComponent("manifest.json"), relativeTo: source)
          == sourceManifest
      else {
        throw MisoError.invalid("Source bundle changed during Base construction")
      }
      let files = try ImageBundle.requiredFiles.sorted().map {
        try Artifacts.record(bundle.appendingPathComponent($0), relativeTo: bundle)
      }
      for record in files where record.path != "disk.img" {
        guard original.files.contains(record) else {
          throw MisoError.invalid("Base static layer changed machine identity")
        }
      }
      manifest["files"] = try JSONSerialization.jsonObject(with: JSON.encode(files))
      manifest["base_complete"] = false
      var stages = manifest["base_stages"] as? [String] ?? []
      stages.append("base-static")
      manifest["base_stages"] = stages
      manifest["runtime_verified"] = false
      manifest["cross_mac_verified"] = false
      try SafeFile.writeNew(
        JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
        to: bundle.appendingPathComponent("manifest.json"))
      _ = try ImageBundle.verify(bundle)
      return Receipt(
        target: profile.release, sourceManifest: sourceManifest, files: files,
        runnerVersion: runnerRelease.tagName, payloadEntries: written.count,
        originalsUnchanged: true, staticPayloadVerified: true,
        baseComplete: false, runtimeVerified: false)
    }
  }

  private static func mainContainer(_ session: DiskImageSession) throws -> APFSTopology.Container {
    let containers = try session.containers().filter {
      $0.volumes.contains(where: { $0.roles == ["System"] })
    }
    guard containers.count == 1, let main = containers.first else {
      throw MisoError.invalid("Ambiguous System container")
    }
    return main
  }

  private static func verifySystem(image: URL, target: MacOSRelease, journal: ExecutionJournal)
    throws
  {
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment { session in
      let main = try mainContainer(session)
      let system = try ImageMounts.mount(
        main.volume(role: "System"), session: session, journal: journal, name: "system",
        readOnly: true)
      let version = try system.plist("System/Library/CoreServices/SystemVersion.plist")
      guard version["ProductVersion"] as? String == target.version,
        version["ProductBuildVersion"] as? String == target.build
      else {
        throw MisoError.invalid("Mounted System version differs from source manifest")
      }
    }
  }

  static func install(
    data: GuestVolume, username: String, nodeFormula: String, runner: URL,
    entries: [TarPayload.Entry], knownHosts: Data, cancellation: CancellationToken?
  ) throws -> [String] {
    let home = "Users/" + username
    let account = try data.plist("private/var/db/dslocal/nodes/Default/users/\(username).plist")
    guard let uidValues = account["uid"] as? [String], uidValues.count == 1,
      let uidText = uidValues.first, let uid = UInt32(uidText),
      let gidValues = account["gid"] as? [String], gidValues.count == 1,
      let gidText = gidValues.first, let gid = UInt32(gidText),
      (501...60_000).contains(uid), (20...60_000).contains(gid),
      account["home"] as? [String] == ["/" + home]
    else { throw MisoError.invalid("Unexpected target account identity") }
    let paths = [
      home + "/.zprofile", home + "/.profile", home + "/.ssh", home + "/actions-runner",
      "Users/runner", "Library/LaunchDaemons/limit.maxfiles.plist",
      "Library/LaunchDaemons/dev.macos-image.tart-guest-daemon.plist",
      "Library/LaunchAgents/dev.macos-image.tart-guest-agent.plist",
    ]
    for relative in paths {
      let path = try data.path(relative, createParents: true, allowLeafLink: true)
      var info = stat()
      guard lstat(path.path, &info) != 0, errno == ENOENT else {
        throw MisoError.invalid("Base output already exists: \(relative)")
      }
    }
    func directory(_ relative: String, mode: mode_t) throws {
      let path = try data.path(relative)
      try SafeFile.makeDirectory(path)
      guard chown(path.path, uid, gid) == 0, chmod(path.path, mode) == 0 else {
        throw MisoError.system("Create Base directory", errno)
      }
    }
    let profile = """
      export LANG=en_US.UTF-8
      eval "$(/opt/homebrew/bin/brew shellenv)"
      export HOMEBREW_NO_AUTO_UPDATE=1
      export HOMEBREW_NO_INSTALL_CLEANUP=1
      eval "$(rbenv init - zsh)"
      export PATH="/opt/homebrew/opt/\(nodeFormula)/bin:$PATH"

      """
    try data.write(paths[0], data: Data(profile.utf8), uid: uid, gid: gid)
    for (relative, target, owner, group) in [
      (paths[1], "/" + home + "/.zprofile", uid, gid), ("Users/runner", "/" + home, 0, 0),
    ] {
      let path = try data.path(relative)
      guard symlink(target, path.path) == 0, lchown(path.path, owner, group) == 0 else {
        throw MisoError.system("Create Base account link", errno)
      }
    }
    try directory(home + "/.ssh", mode: 0o700)
    try data.write(home + "/.ssh/known_hosts", data: knownHosts, uid: uid, gid: gid, mode: 0o600)
    try data.mergePlist(
      paths[5],
      values: [
        "Label": "limit.maxfiles", "RunAtLoad": true, "ServiceIPC": false,
        "ProgramArguments": ["/bin/launchctl", "limit", "maxfiles", "65536", "524288"],
      ])
    for (relative, role) in [(paths[6], "daemon"), (paths[7], "agent")] {
      var plist: [String: Any] = [
        "Label": "dev.macos-image.tart-guest-\(role)",
        "ProgramArguments": ["/opt/homebrew/bin/tart-guest-agent", "--run-\(role)"],
        "EnvironmentVariables": [
          "PATH": "/bin:/usr/bin:/usr/sbin:/usr/local/bin:/opt/homebrew/bin",
          "TERM": "xterm-256color",
        ],
        "RunAtLoad": true, "KeepAlive": true, "StandardOutPath": "/tmp/tart-guest-\(role).log",
        "StandardErrorPath": "/tmp/tart-guest-\(role).log",
      ]
      if role == "daemon" { plist["WorkingDirectory"] = "/var/empty" }
      try data.mergePlist(relative, values: plist)
    }
    try directory(home + "/actions-runner", mode: 0o755)
    try TarPayload.extract(
      runner, into: data.path(home + "/actions-runner"), entries: entries, uid: uid, gid: gid,
      cancellation: cancellation)
    return paths
  }

  private static func inventory(
    data: GuestVolume, paths: [String], cancellation: CancellationToken?
  ) throws -> [PayloadEntry] {
    var result: [PayloadEntry] = []
    func visit(_ relative: String) throws {
      try cancellation?.check()
      let path = try data.path(relative, allowLeafLink: true)
      let info = try FileMetadata.inspect(path)
      let kind = info.st_mode & S_IFMT
      guard [S_IFREG, S_IFDIR, S_IFLNK].contains(kind) else {
        throw MisoError.invalid("Unexpected Base payload type")
      }
      result.append(
        PayloadEntry(
          path: relative, uid: info.st_uid, gid: info.st_gid, mode: info.st_mode,
          bytes: kind == S_IFREG ? UInt64(info.st_size) : nil,
          sha256: kind == S_IFREG ? try SafeFile.sha256(path) : nil,
          link: kind == S_IFLNK
            ? try FileManager.default.destinationOfSymbolicLink(atPath: path.path) : nil))
      if kind == S_IFDIR {
        for name in try FileManager.default.contentsOfDirectory(atPath: path.path).sorted() {
          try visit(relative + "/" + name)
        }
      }
    }
    for path in paths.sorted() { try visit(path) }
    return result
  }
}

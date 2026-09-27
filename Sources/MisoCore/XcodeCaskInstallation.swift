import Darwin
import Foundation

public enum XcodeCaskInstallation {
  public struct Details: Encodable {
    let installed: [String: String]
    let probes: [String: String]
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
  }

  public struct Receipt: Encodable {
    let input: XcodeCaskInputs.Receipt
    let image: BaseStageReceipt<Details>
    let temporaryInputsRemoved: Bool
    let vmStarted = false
  }

  public static func install(
    source: URL, prepared: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Cask installation requires administrator privileges")
    }
    let previous = try JSON.read(
      XcodeCaskInputs.Receipt.self, from: GuestVolume(prepared).path("casks.json"))
    let journal = try ExecutionJournal(
      output: output, operation: "install-xcode-casks", cancellation: cancellation)
    do {
      let inputs = output.appendingPathComponent("inputs")
      let input = try await XcodeCaskInputs.prepare(
        target: previous.target, output: inputs, cache: prepared, cancellation: journal.cancellation
      )
      let image = try BaseImageStage.run(
        source: source, output: output.appendingPathComponent("image"), operation: "xcode-casks",
        layer: .xcode, cancellation: journal.cancellation
      ) { bundle, target, stage in
        guard target == input.target else {
          throw MisoError.invalid("Cask target differs from image")
        }
        return try install(
          input, inputs: inputs, image: bundle.appendingPathComponent("disk.img"),
          username: username, journal: stage)
      }
      try BaseStageWorkspace.requireUnmounted(inputs)
      for item in input.items {
        let directory = try GuestVolume(GuestVolume(inputs).directory(item.cask.token).url)
        try FileManager.default.removeItem(at: directory.directory("expanded").url)
        try FileManager.default.removeItem(at: directory.path(item.cask.filename))
      }
      let result = Receipt(input: input, image: image, temporaryInputsRemoved: true)
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  private static func install(
    _ input: XcodeCaskInputs.Receipt, inputs: URL, image: URL, username: String,
    journal: ExecutionJournal
  ) throws -> Details {
    let root = try BaseExecutionView.prepare(image: image, target: input.target, journal: journal)
    let paths = ["opt/homebrew", "Applications/Kiro CLI.app"]
    var identity: [UInt32] = []
    var installed: [String: String] = [:]
    var probes: [String: String] = [:]
    let payload = try GuestExecution.withSession(
      image: image, root: root, username: username, journal: journal
    ) { guest in
      try guest.verifyControls(target: input.target)
      identity = [guest.account.uid, guest.account.gid]
      let execution = try HomebrewExecution(guest: guest)
      defer { try? execution.remove() }
      try execution.verify()
      func brew(_ name: String, _ arguments: [String]) throws -> String {
        try guest.run(
          name, arguments: GuestExecution.brewArguments(arguments, username: username),
          capability: .cask, timeout: 300)
      }
      let before = try BaseBottles.installedVersions(
        brew("casks-before", ["list", "--cask", "--versions"]))
      var expected = before
      guard !input.items.contains(where: { before[$0.cask.token] != nil }),
        try !guest.data.contains("Applications/Kiro CLI.app")
      else { throw MisoError.invalid("Developer cask already exists") }
      try guest.data.makeDirectories(
        "opt/homebrew/Caskroom", uid: guest.account.uid, gid: guest.account.gid)
      let applications = try guest.data.directory("Applications").url
      let parent = try FileMetadata.inspect(applications)
      guard chown(applications.path, guest.account.uid, guest.account.gid) == 0 else {
        throw MisoError.system("Prepare application staging access", errno)
      }
      func restore() throws {
        guard try FileMetadata.inspect(applications).st_ino == parent.st_ino,
          chown(applications.path, parent.st_uid, parent.st_gid) == 0,
          chmod(applications.path, parent.st_mode & 0o7777) == 0
        else { throw MisoError.invalid("Cannot restore application directory ownership") }
      }
      do {
        let denied = "Applications/.miso-cask-control"
        guard try !guest.data.contains(denied) else {
          throw MisoError.invalid("Cask control path exists")
        }
        try guest.run(
          "cask-outside-denial", arguments: ["/bin/sh", "-c", "printf denied > /" + denied],
          capability: .cask, expectedExitCodes: [1, 2])
        guard try !guest.data.contains(denied) else {
          throw MisoError.invalid("Cask execution can change unrelated applications")
        }
        for item in input.items {
          let cask = item.cask
          let directory = "opt/homebrew/Caskroom/" + cask.token
          try guest.data.makeDirectories(directory, uid: guest.account.uid, gid: guest.account.gid)
          let destination = try guest.data.path(directory + "/" + cask.version)
          guard try !guest.data.contains(directory + "/" + cask.version) else {
            throw MisoError.invalid("Cask staging destination exists")
          }
          let original = try GuestVolume(inputs).directory(cask.token + "/expanded").url
          let inventory = try JSON.read(
            [BaseInputArchive.Entry].self, from: Artifacts.resolve(item.inventory, under: inputs))
          guard
            try BaseInputArchive.inventory(original, cancellation: journal.cancellation)
              == inventory
          else { throw MisoError.invalid("Prepared cask tree changed") }
          try BaseFileTree.copy(
            original, to: destination, entries: inventory, uid: guest.account.uid,
            gid: guest.account.gid, cancellation: journal.cancellation)
          guard chmod(destination.path, 0o755) == 0 else {
            throw MisoError.system("Set cask staging directory mode", errno)
          }
          let metadataPath = directory + "/.miso-input.json"
          try guest.data.write(
            metadataPath,
            data: SafeFile.read(Artifacts.resolve(item.metadata, under: inputs), limit: 1 << 20),
            uid: guest.account.uid, gid: guest.account.gid)
          _ = try brew(
            "install-cask-artifacts",
            execution.rubyArguments(
              program: installProgram,
              arguments: [
                "/" + metadataPath, cask.token, cask.version, cask.url.absoluteString, cask.sha256,
              ]))
          try FileManager.default.removeItem(at: guest.data.path(metadataPath))
          let executable = cask.token == "claude-code" ? "claude" : cask.token
          let version = try guest.run(
            "cask-version", arguments: ["/opt/homebrew/bin/" + executable, "--version"],
            capability: .cask, timeout: 90)
          guard version.contains(cask.version) else {
            throw MisoError.invalid("Cask version probe differs from prepared input")
          }
          probes[cask.token] = version
          expected[cask.token] = cask.version
        }
        try restore()
      } catch {
        try restore()
        throw error
      }
      installed = try BaseBottles.installedVersions(
        brew("casks-after", ["list", "--cask", "--versions"]))
      guard installed == expected else {
        throw MisoError.invalid("Installed casks differ from requested versions")
      }
      try journal.run(
        "verify-installed-cask-application",
        NativeCommand(
          .codesign,
          arguments: [
            "--verify", "--deep", "--strict",
            guest.data.directory("Applications/Kiro CLI.app").url.path,
          ], timeout: 180))
      try execution.remove()
      return try Dictionary(
        uniqueKeysWithValues: paths.map { path in
          let entries = try BaseFileTree.inventory(
            guest.data, path: path, cancellation: journal.cancellation)
          try BaseFileTree.requireOwnership(
            guest.data.path(path), entries: entries, uid: guest.account.uid, gid: guest.account.gid)
          return (path, entries)
        })
    }
    try SafeFile.writeNew(
      JSON.encode(payload), to: journal.output.appendingPathComponent("cask-payload.json"))
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment { session in
      let data = try ImageMounts.mount(
        BaseImageStage.mainContainer(session).volume(role: "Data"), session: session,
        journal: journal, name: "cask-audit", readOnly: true)
      let account = try BaseImageStage.Account(username, data: data)
      guard [account.uid, account.gid] == identity else {
        throw MisoError.invalid("Cask account changed")
      }
      for path in paths {
        guard let entries = payload[path],
          try BaseFileTree.inventory(data, path: path, cancellation: journal.cancellation)
            == entries
        else { throw MisoError.invalid("Detached cask payload verification failed") }
        try BaseFileTree.requireOwnership(
          data.path(path), entries: entries, uid: account.uid, gid: account.gid)
      }
    }
    return Details(
      installed: installed, probes: probes,
      payloadEntries: payload.values.reduce(0) { $0 + $1.count }, detachedPayloadVerified: true,
      executionControlsVerified: true)
  }

  static let installProgram = """
    require 'json'; require 'cask/cask_loader'; require 'cask/installer'
    file, token, version, url, sha = ARGV
    cask = Cask::CaskLoader::FromAPILoader.new(token, from_json: JSON.parse(File.read(file)), path: Pathname(file), api_fallback: false).load(config: nil)
    raise 'Cask identity differs' unless cask.token == token && cask.version.to_s == version && cask.url.to_s == url && cask.sha256.to_s == sha
    raise 'Cask already installed' if cask.installed?
    raise 'Cask payload absent' unless cask.staged_path.directory?
    installer = Cask::Installer.new(cask, installed_on_request: true)
    installer.send(:prelude)
    installer.send(:save_caskfile)
    installer.install_artifacts
    tab = Cask::Tab.create(cask)
    tab.installed_on_request = true
    tab.write
    raise 'Cask registration failed' unless cask.installed?
    """
}

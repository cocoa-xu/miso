import Darwin
import Foundation

public enum XcodeTuistInstallation {
  public struct Details: Encodable {
    let version: String
    let probes: [String: String]
    let payloadEntries: Int
    let profileSHA256: String
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
    let runtimeVerified = false
  }

  public struct Receipt: Encodable {
    let input: XcodeTuistInputs.Receipt
    let image: BaseStageReceipt<Details>
    let temporaryInputsRemoved: Bool
    let vmStarted = false
  }

  public static func install(
    source: URL, prepared: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Tuist installation requires administrator privileges")
    }
    let previous = try JSON.read(
      XcodeTuistInputs.Receipt.self, from: GuestVolume(prepared).path("tuist.json"))
    let journal = try ExecutionJournal(
      output: output, operation: "install-xcode-tuist", cancellation: cancellation)
    do {
      let inputs = output.appendingPathComponent("inputs")
      let input = try await XcodeTuistInputs.prepare(
        target: previous.target, output: inputs, cache: prepared, cancellation: journal.cancellation
      )
      let image = try BaseImageStage.run(
        source: source, output: output.appendingPathComponent("image"), operation: "xcode-tuist",
        layer: .xcode, cancellation: journal.cancellation
      ) { bundle, target, stage in
        guard target == input.target else {
          throw MisoError.invalid("Tuist target differs from image")
        }
        return try install(
          input, inputs: inputs, image: bundle.appendingPathComponent("disk.img"),
          username: username, journal: stage)
      }
      try BaseStageWorkspace.requireUnmounted(inputs)
      try FileManager.default.removeItem(at: inputs.appendingPathComponent("expanded"))
      try FileManager.default.removeItem(at: Artifacts.resolve(input.archive, under: inputs))
      let result = Receipt(input: input, image: image, temporaryInputsRemoved: true)
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  private static func install(
    _ input: XcodeTuistInputs.Receipt, inputs: URL, image: URL, username: String,
    journal: ExecutionJournal
  ) throws -> Details {
    let root = try BaseExecutionView.prepare(image: image, target: input.target, journal: journal)
    let home = "Users/" + username
    let tool = "Library/Developer/MISO/Tuist/" + input.formula.version
    let paths = [
      tool, home + "/.local/share/mise", home + "/.config/mise", home + "/.local/state/mise",
    ]
    var probes: [String: String] = [:]
    var identity: [UInt32] = []
    var profileSHA256 = ""
    let payload = try GuestExecution.withSession(
      image: image, root: root, username: username, journal: journal
    ) { guest in
      try guest.verifyControls(target: input.target)
      identity = [guest.account.uid, guest.account.gid]
      let configuration = XcodeConfiguration()
      _ = try XcodeArchive.inspect(
        guest.data.directory(configuration.applicationPath).url, target: input.target,
        configuration: configuration)
      for path in paths {
        guard try !guest.data.contains(path) else {
          throw MisoError.invalid("Tuist destination already exists: \(path)")
        }
      }
      let expanded = inputs.appendingPathComponent("expanded")
      let inventory = try JSON.read(
        [BaseInputArchive.Entry].self, from: Artifacts.resolve(input.inventory, under: inputs))
      guard
        try BaseInputArchive.inventory(expanded, cancellation: journal.cancellation) == inventory
      else {
        throw MisoError.invalid("Tuist input tree changed")
      }
      try guest.data.makeDirectories("Library/Developer/MISO/Tuist", uid: 0, gid: 0)
      try BaseFileTree.copy(
        expanded, to: guest.data.path(tool), entries: inventory, uid: guest.account.uid,
        gid: guest.account.gid, cancellation: journal.cancellation)
      for path in paths.dropFirst() {
        try guest.data.makeDirectories(path, uid: guest.account.uid, gid: guest.account.gid)
      }
      let denied = home + "/.config/.miso-mise-control"
      guard try !guest.data.contains(denied) else {
        throw MisoError.invalid("Mise isolation control path exists")
      }
      try guest.run(
        "mise-outside-denial", arguments: ["/bin/sh", "-c", "printf denied > /" + denied],
        capability: .mise, expectedExitCodes: [1, 2])
      guard try !guest.data.contains(denied) else {
        throw MisoError.invalid("Mise can change unrelated configuration")
      }
      let environment = [
        "/usr/bin/env", "MISE_OFFLINE=true", "MISE_YES=1", "MISE_COLOR=0",
        "MISE_DATA_DIR=/" + home + "/.local/share/mise",
        "MISE_CONFIG_DIR=/" + home + "/.config/mise",
        "MISE_STATE_DIR=/" + home + "/.local/state/mise",
        "MISE_CACHE_DIR=/" + home + "/Library/Caches/mise",
      ]
      func mise(_ name: String, _ arguments: [String]) throws -> String {
        try guest.run(
          name, arguments: environment + ["/opt/homebrew/bin/mise"] + arguments, capability: .mise,
          timeout: 180)
      }
      let selection = "tuist@" + input.formula.version
      probes["link"] = try mise("mise-link-tuist", ["link", selection, "/" + tool])
      probes["pin"] = try mise("mise-pin-tuist", ["use", "--global", "--pin", selection])
      _ = try mise("mise-reshim-tuist", ["reshim"])
      probes["location"] = try mise("mise-tuist-location", ["where", selection])
      guard
        ["/" + tool, "/" + home + "/.local/share/mise/installs/tuist/" + input.formula.version]
          .contains(probes["location"] ?? ""),
        try FileManager.default.destinationOfSymbolicLink(
          atPath: guest.data.path(
            home + "/.local/share/mise/installs/tuist/" + input.formula.version, allowLeafLink: true
          ).path) == "/" + tool
      else { throw MisoError.invalid("Mise Tuist registration differs from installed payload") }
      probes["executable"] = try mise("mise-tuist-executable", ["which", "tuist"])
      let executable = "/" + home + "/.local/share/mise/installs/tuist/" + input.formula.version
      let miseLink = try FileManager.default.destinationOfSymbolicLink(
        atPath: guest.data.path("opt/homebrew/bin/mise", allowLeafLink: true).path)
      let miseTarget = URL(fileURLWithPath: "/opt/homebrew/bin")
        .appendingPathComponent(miseLink).standardizedFileURL.path
      let shimTarget = try FileManager.default.destinationOfSymbolicLink(
        atPath: guest.data.path(
          home + "/.local/share/mise/shims/tuist", allowLeafLink: true
        ).path)
      guard ["/" + tool + "/tuist", executable + "/tuist"].contains(probes["executable"] ?? ""),
        miseTarget.hasPrefix("/opt/homebrew/Cellar/mise/"), miseTarget.hasSuffix("/bin/mise"),
        shimTarget == miseTarget,
        try FileMetadata.inspect(guest.data.path(String(miseTarget.dropFirst()))).st_mode & S_IFMT
          == S_IFREG
      else { throw MisoError.invalid("Mise cannot resolve the pinned Tuist executable") }
      let installedTool = try guest.data.path(tool + "/tuist")
      guard
        try SafeFile.sha256(installedTool)
          == SafeFile.sha256(expanded.appendingPathComponent("tuist"))
      else { throw MisoError.invalid("Installed Tuist differs from its signed input") }
      try journal.run(
        "verify-installed-tuist-signature",
        NativeCommand(.codesign, arguments: ["--verify", "--strict", installedTool.path]))
      let profile = home + "/.zprofile"
      let data = try shellProfile(SafeFile.read(guest.data.path(profile), limit: 1 << 20))
      let mode = try FileMetadata.inspect(guest.data.path(profile)).st_mode & 0o777
      try guest.data.write(
        profile, data: data, uid: guest.account.uid, gid: guest.account.gid, mode: mode)
      profileSHA256 = try SafeFile.sha256(guest.data.path(profile))
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
      JSON.encode(payload), to: journal.output.appendingPathComponent("tuist-payload.json"))
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment { session in
      let data = try ImageMounts.mount(
        BaseImageStage.mainContainer(session).volume(role: "Data"), session: session,
        journal: journal, name: "tuist-audit", readOnly: true)
      let account = try BaseImageStage.Account(username, data: data)
      guard [account.uid, account.gid] == identity,
        try SafeFile.sha256(data.path(home + "/.zprofile")) == profileSHA256
      else {
        throw MisoError.invalid("Detached Tuist account or profile differs")
      }
      for path in paths {
        guard let entries = payload[path],
          try BaseFileTree.inventory(data, path: path, cancellation: journal.cancellation)
            == entries
        else {
          throw MisoError.invalid("Detached Tuist payload differs")
        }
        try BaseFileTree.requireOwnership(
          data.path(path), entries: entries, uid: account.uid, gid: account.gid)
      }
    }
    return Details(
      version: input.formula.version, probes: probes,
      payloadEntries: payload.values.reduce(0) { $0 + $1.count }, profileSHA256: profileSHA256,
      detachedPayloadVerified: true, executionControlsVerified: true)
  }

  static func shellProfile(_ data: Data) throws -> Data {
    guard data.count <= 1 << 20, let text = String(data: data, encoding: .utf8),
      !text.contains("\0")
    else {
      throw MisoError.invalid("Invalid shell profile")
    }
    let line = #"export PATH="$HOME/.local/share/mise/shims:$PATH""#
    if text.split(separator: "\n").contains(Substring(line)) { return data }
    return Data((text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + line + "\n").utf8)
  }
}

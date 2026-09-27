import Darwin
import Foundation

public enum BaseBottles {
  public struct Details: Codable {
    let selection: HomebrewBottleInputs.Selection
    let installed: [String: String]
    let deferredPostInstall: [String]
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let executionControlsVerified: Bool
    let lifecycleProbes: [String: String]?
  }

  public static func run(
    source: URL, resolution: URL, bottles: URL, names: [String], output: URL,
    username: String = "admin", postInstall: Bool = false, cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let selection = try HomebrewBottleInputs.load(
      resolution: resolution, bottles: bottles, names: names, cancellation: cancellation)
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-bottles", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == selection.target else {
        throw MisoError.invalid("Bottle resolution target differs from image")
      }
      try SafeFile.writeNew(
        JSON.encode(selection), to: output.appendingPathComponent("bottles.json"))
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      var installed: [String: String] = [:]
      var accountIdentity: [UInt32] = []
      var lifecycleProbes: [String: String]?
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        accountIdentity = [guest.account.uid, guest.account.gid]
        try guest.verifyControls(target: target)
        let before = try installedVersions(
          guest.run(
            "bottles-before",
            arguments: GuestExecution.brewArguments(
              ["list", "--formula", "--versions"], username: username), capability: .brew))
        let relative = "Users/\(username)/.miso-bottles-" + UUID().uuidString
        let staging = try guest.data.path(relative)
        try SafeFile.makeDirectory(staging)
        guard chmod(staging.path, 0o755) == 0 else {
          throw MisoError.system("Set bottle staging permissions", errno)
        }
        let stagingIdentity = try FileMetadata.inspect(staging)
        var expected = before
        for payload in selection.payloads {
          let formula = payload.formula
          let sourcePath = formula.sourceURL.pathComponents.dropFirst(4).joined(separator: "/")
          let tapPath = "opt/homebrew/Library/Taps/homebrew/homebrew-core/" + sourcePath
          guard try SafeFile.sha256(guest.data.path(tapPath)) == formula.sourceSHA256 else {
            throw MisoError.invalid(
              "Installed formula source differs from resolution: \(formula.name)")
          }
          if let current = before[formula.name] {
            guard current == formula.kegVersion else {
              throw MisoError.invalid(
                "Installed formula conflicts with resolution: \(formula.name)")
            }
            continue
          }
          let origin = try Artifacts.resolve(
            payload.archive, under: bottles,
            cancellation: journal.cancellation)
          let archive = staging.appendingPathComponent(payload.filename)
          try Artifacts.copy(
            origin, to: archive, maximumBytes: payload.archive.bytes,
            cancellation: journal.cancellation)
          guard try SafeFile.sha256(archive) == payload.archive.sha256,
            chmod(archive.path, 0o444) == 0
          else {
            throw MisoError.invalid("Staged bottle differs from input")
          }
          try guest.data.write(
            relative + "/" + payload.sidecarName,
            data: JSON.encode(payload.sidecar), mode: 0o444)
          try guest.run(
            "install-bottle",
            arguments: GuestExecution.brewArguments(
              ["install", "--skip-post-install", "/" + relative + "/" + payload.filename],
              username: username), capability: .brew, timeout: 600)
          expected[formula.name] = formula.kegVersion
        }
        if postInstall {
          lifecycleProbes = try HomebrewLifecycle.run(
            selection.payloads.map(\.formula), guest: guest)
        }
        installed = try installedVersions(
          guest.run(
            "bottles-after",
            arguments: GuestExecution.brewArguments(
              ["list", "--formula", "--versions"],
              username: username), capability: .brew))
        guard installed == expected else {
          throw MisoError.invalid("Installed formula versions differ from requested payloads")
        }
        for payload in selection.payloads {
          let receipt = try JSON.read(
            JSONValue.self,
            from: guest.data.path(
              "opt/homebrew/Cellar/\(payload.formula.name)/\(payload.formula.kegVersion)/INSTALL_RECEIPT.json"
            ))
          guard case .object(let fields) = receipt, fields["poured_from_bottle"] == .bool(true)
          else {
            throw MisoError.invalid("Formula was not installed from a bottle")
          }
        }
        let current = try FileMetadata.inspect(guest.data.path(relative))
        guard current.st_dev == stagingIdentity.st_dev, current.st_ino == stagingIdentity.st_ino,
          current.st_mode & S_IFMT == S_IFDIR
        else {
          throw MisoError.invalid("Bottle staging directory identity changed")
        }
        try FileManager.default.removeItem(at: staging)
        let prefix = try guest.data.path("opt/homebrew")
        let inventory = try BaseFileTree.inventory(
          guest.data, path: "opt/homebrew", cancellation: journal.cancellation)
        try BaseFileTree.requireOwnership(
          prefix, entries: inventory,
          uid: guest.account.uid, gid: guest.account.gid)
        return inventory
      }
      try SafeFile.writeNew(
        JSON.encode(payload), to: output.appendingPathComponent("bottle-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let container = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          container.volume(role: "Data"), session: session,
          journal: journal, name: "bottle-audit", readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == accountIdentity else {
          throw MisoError.invalid("Target account changed during bottle installation")
        }
        guard
          try BaseFileTree.inventory(
            data, path: "opt/homebrew",
            cancellation: journal.cancellation) == payload
        else {
          throw MisoError.invalid("Detached bottle payload verification failed")
        }
        try BaseFileTree.requireOwnership(
          data.path("opt/homebrew"), entries: payload,
          uid: account.uid, gid: account.gid)
      }
      for payload in selection.payloads {
        _ = try Artifacts.resolve(
          payload.archive, under: bottles, cancellation: journal.cancellation)
        _ = try Artifacts.resolve(payload.index, under: bottles, cancellation: journal.cancellation)
      }
      guard
        try SafeFile.sha256(resolution.appendingPathComponent("resolution.json"))
          == selection.resolutionSHA256
      else {
        throw MisoError.invalid("Bottle resolution changed during installation")
      }
      return Details(
        selection: selection, installed: installed,
        deferredPostInstall: selection.payloads.filter { $0.formula.hasPostInstall && !postInstall }
          .map {
            $0.formula.name
          },
        payloadEntries: payload.count, detachedPayloadVerified: true,
        executionControlsVerified: true, lifecycleProbes: lifecycleProbes)
    }
  }

  static func installedVersions(_ text: String) throws -> [String: String] {
    var result: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count == 2, result[fields[0]] == nil else {
        throw MisoError.invalid("Ambiguous installed formula versions")
      }
      try PackageRequest(name: fields[0]).validate()
      result[fields[0]] = fields[1]
    }
    return result
  }
}

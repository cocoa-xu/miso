import Darwin
import Foundation

public enum BaseGCM {
  public struct Details: Codable {
    let plan: BaseGCMInputs.Plan
    let planSHA256: String
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let gitConfigurationVerified: Bool
    let packagePostinstallExecuted: Bool
    let gcmRuntimeVerified: Bool
  }

  public static func run(
    source: URL, plan planURL: URL, inputs: URL, output: URL,
    username: String = "admin", cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planSHA256 = try SafeFile.sha256(planURL)
    let plan = try BaseGCMInputs.verify(plan: planURL, inputs: inputs, cancellation: cancellation)
    let metadata = try BaseGCMInputs.metadata(plan, inputs: inputs)
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-gcm", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == plan.target else {
        throw MisoError.invalid("Credential manager target mismatch")
      }
      try journal.setMetadata("gcmPlan", value: plan)
      let package = try Artifacts.resolve(
        plan.package, under: inputs, cancellation: journal.cancellation)
      let prepared = try BaseGCMPackage.prepare(package, version: plan.version, journal: journal)
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      let paths = [BaseGCMPackage.prefix, "opt/homebrew/Caskroom/git-credential-manager"]
      let receipt = "private/var/db/receipts/" + BaseGCMPackage.identifier
      let recipePath = "Users/\(username)/base-inputs/git-credential-manager.rb"
      let files = [
        receipt + ".plist", receipt + ".bom", recipePath, "Users/\(username)/.gitconfig",
      ]
      var identity: [UInt32] = []
      var fileRecords: [ImageBundle.FileRecord] = []
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        identity = [guest.account.uid, guest.account.gid]
        try guest.verifyControls(target: target)
        for path in paths + [receipt + ".plist", receipt + ".bom", recipePath] {
          guard !(try guest.data.contains(path)) else {
            throw MisoError.invalid("Credential manager destination already exists: \(path)")
          }
        }
        try directory("usr/local/share", data: guest.data)
        try BaseFileTree.copy(
          prepared.payload, to: guest.data.path(BaseGCMPackage.prefix),
          entries: prepared.inventory, uid: 0, gid: 0, cancellation: journal.cancellation)
        try directory("usr/local/bin", data: guest.data)
        let link = try guest.data.path("usr/local/bin/git-credential-manager")
        guard symlink("/" + BaseGCMPackage.prefix + "/git-credential-manager", link.path) == 0,
          lchown(link.path, 0, 0) == 0, lchmod(link.path, 0o755) == 0
        else { throw MisoError.system("Create credential manager link", errno) }
        try directory("private/var/db/receipts", data: guest.data)
        try guest.data.mergePlist(
          receipt + ".plist",
          values: [
            "PackageIdentifier": BaseGCMPackage.identifier, "PackageVersion": plan.version,
            "PackageFileName": package.lastPathComponent,
            "InstallPrefixPath": "/" + BaseGCMPackage.prefix, "InstallDate": Date(),
            "InstallProcessName": "miso",
          ])
        try guest.data.write(receipt + ".bom", data: SafeFile.read(prepared.bom, limit: 16 << 20))
        try verifyReceipt(plan, data: guest.data, journal: journal)
        try configure(guest)
        try guest.data.makeDirectories(
          "Users/\(username)/base-inputs", uid: guest.account.uid, gid: guest.account.gid)
        try guest.data.write(
          recipePath,
          data: SafeFile.read(GuestVolume(inputs).path(plan.recipe.path), limit: 1 << 20),
          uid: guest.account.uid, gid: guest.account.gid, mode: 0o444)
        _ = try guest.run(
          "gcm-cask-register",
          arguments: GuestExecution.brewArguments(
            [
              "ruby", "-e",
              registrationProgram(plan, tapRevision: metadata.tapRevision, username: username),
            ], username: username), capability: .base)
        let casks = try guest.run(
          "gcm-cask-list",
          arguments: GuestExecution.brewArguments(
            [
              "list", "--cask", "--versions", "git-credential-manager",
            ], username: username), capability: .base)
        guard casks == "git-credential-manager " + plan.version else {
          throw MisoError.invalid("Credential manager cask registration failed")
        }
        fileRecords = try files.map {
          try Artifacts.record(guest.data.path($0), relativeTo: guest.data.root)
        }
        let inventory = try Dictionary(
          uniqueKeysWithValues: paths.map { path in
            (
              path,
              try BaseFileTree.inventory(guest.data, path: path, cancellation: journal.cancellation)
            )
          })
        try verifyOwnership(guest.data, inventory: inventory, files: files, account: guest.account)
        return inventory
      }
      try SafeFile.writeNew(
        JSON.encode(payload), to: output.appendingPathComponent("gcm-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let container = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          container.volume(role: "Data"), session: session,
          journal: journal, name: "gcm-audit", readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == identity else {
          throw MisoError.invalid("Credential manager account changed")
        }
        for path in paths {
          guard
            try BaseFileTree.inventory(data, path: path, cancellation: journal.cancellation)
              == payload[path]
          else {
            throw MisoError.invalid("Detached credential manager payload differs")
          }
        }
        guard
          try files.map({ try Artifacts.record(data.path($0), relativeTo: data.root) })
            == fileRecords
        else {
          throw MisoError.invalid("Detached credential manager configuration differs")
        }
        try verifyOwnership(data, inventory: payload, files: files, account: account)
        try verifyReceipt(plan, data: data, journal: journal)
      }
      _ = try BaseGCMInputs.verify(
        plan: planURL, inputs: inputs, cancellation: journal.cancellation)
      guard try SafeFile.sha256(planURL) == planSHA256 else {
        throw MisoError.invalid("Credential manager plan changed")
      }
      return Details(
        plan: plan, planSHA256: planSHA256,
        payloadEntries: payload.values.reduce(0) { $0 + $1.count }, detachedPayloadVerified: true,
        gitConfigurationVerified: true, packagePostinstallExecuted: false, gcmRuntimeVerified: false
      )
    }
  }

  private static func directory(_ relative: String, data: GuestVolume) throws {
    var current = ""
    for part in try SafeFile.relativePath(relative).split(separator: "/") {
      current += (current.isEmpty ? "" : "/") + part
      if !(try data.contains(current)) {
        let url = try data.path(current)
        try SafeFile.makeDirectory(url)
        guard chown(url.path, 0, 0) == 0, chmod(url.path, 0o755) == 0 else {
          throw MisoError.system("Set credential manager directory metadata", errno)
        }
      }
      _ = try data.directory(current)
    }
  }

  private static func verifyReceipt(
    _ plan: BaseGCMInputs.Plan, data: GuestVolume, journal: ExecutionJournal
  ) throws {
    struct Installed: Decodable {
      let version: String
      enum CodingKeys: String, CodingKey { case version = "pkg-version" }
    }
    let installed = try journal.plist(
      Installed.self, name: "gcm-receipt-readback",
      command: NativeCommand(
        .packages,
        arguments: [
          "--volume", data.root.path,
          "--pkg-info-plist", BaseGCMPackage.identifier,
        ]))
    guard installed.version == plan.version else {
      throw MisoError.invalid("Credential manager receipt readback failed")
    }
  }

  private static func verifyOwnership(
    _ data: GuestVolume, inventory: [String: [BaseInputArchive.Entry]],
    files: [String], account: BaseImageStage.Account
  ) throws {
    for (path, entries) in inventory {
      let rootOwned = path == BaseGCMPackage.prefix
      try BaseFileTree.requireOwnership(
        data.path(path), entries: entries,
        uid: rootOwned ? 0 : account.uid, gid: rootOwned ? 0 : account.gid)
    }
    for path in files {
      let userOwned = path.hasPrefix("Users/")
      let info = try FileMetadata.inspect(data.path(path))
      guard info.st_uid == (userOwned ? account.uid : 0),
        info.st_gid == (userOwned ? account.gid : 0),
        info.st_mode & S_IFMT == S_IFREG
      else { throw MisoError.invalid("Credential manager file ownership differs") }
    }
    let link = try data.path("usr/local/bin/git-credential-manager", allowLeafLink: true)
    let info = try FileMetadata.inspect(link)
    guard info.st_mode == S_IFLNK | 0o755, info.st_uid == 0, info.st_gid == 0,
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/"
        + BaseGCMPackage.prefix + "/git-credential-manager"
    else { throw MisoError.invalid("Credential manager link differs") }
  }

  private static func configure(_ guest: GuestExecution) throws {
    let git = [
      "/usr/bin/env", "GIT_CONFIG_NOSYSTEM=1", "/Library/Developer/CommandLineTools/usr/bin/git",
      "config", "--global",
    ]
    let before = try guest.run(
      "gcm-git-helper-before", arguments: git + ["--get-all", "credential.helper"],
      capability: .git, expectedExitCodes: [1])
    guard before.isEmpty else {
      throw MisoError.invalid("Credential manager requires an unconfigured user helper")
    }
    for arguments in [
      ["--add", "credential.helper", ""],
      ["--add", "credential.helper", "/" + BaseGCMPackage.prefix + "/git-credential-manager"],
      ["credential.https://dev.azure.com.useHttpPath", "true"],
    ] {
      try guest.run("gcm-git-configure", arguments: git + arguments, capability: .git)
    }
    try guest.run(
      "gcm-git-lfs-configure",
      arguments: [
        "/usr/bin/env",
        "PATH=/Library/Developer/CommandLineTools/usr/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "/opt/homebrew/bin/git-lfs", "install",
      ], capability: .git)
    guard
      try guest.run(
        "gcm-git-helper-readback", arguments: git + ["--null", "--get-all", "credential.helper"],
        capability: .git)
        == "\0/" + BaseGCMPackage.prefix + "/git-credential-manager\0",
      try guest.run(
        "gcm-git-azure-readback",
        arguments: git + ["--get", "credential.https://dev.azure.com.useHttpPath"], capability: .git
      ) == "true"
    else { throw MisoError.invalid("Credential manager Git configuration differs") }
    for (key, value) in [
      ("clean", "git-lfs clean -- %f"), ("smudge", "git-lfs smudge -- %f"),
      ("process", "git-lfs filter-process"), ("required", "true"),
    ] {
      guard
        try guest.run(
          "gcm-git-lfs-readback", arguments: git + ["--get", "filter.lfs." + key], capability: .git)
          == value
      else {
        throw MisoError.invalid("Git LFS configuration differs")
      }
    }
  }

  static func registrationProgram(_ plan: BaseGCMInputs.Plan, tapRevision: String, username: String)
    throws -> String
  {
    try plan.validate()
    guard username.range(of: #"\A[a-z][a-z0-9_-]{0,30}\z"#, options: .regularExpression) != nil,
      tapRevision.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil
    else { throw MisoError.invalid("Invalid credential manager cask identity") }
    return """
      require 'cask/cask_loader'; require 'cask/installer'; require 'cask/tab'
      c = Cask::CaskLoader.load(Pathname('/Users/\(username)/base-inputs/git-credential-manager.rb'))
      raise 'Wrong cask identity' unless c.token == 'git-credential-manager' && c.version.to_s == '\(plan.version)' && c.sha256.to_s == '\(plan.package.sha256)'
      c.staged_path.mkpath
      i = Cask::Installer.new(c); i.send(:save_caskfile); i.send(:save_config_file)
      t = Cask::Tab.create(c); t.source['tap'] = 'homebrew/cask'; t.source['tap_git_head'] = '\(tapRevision)'; t.write
      """
  }
}

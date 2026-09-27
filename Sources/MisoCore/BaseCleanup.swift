import Darwin
import Foundation

public enum BaseCleanup {
  public struct Plan: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let nodeFormula: String
    let pythonFormula: String
    let pythonExecutable: String
    let rubyVersions: [String]
    let certificateBundle: ImageBundle.FileRecord
    let certificateCount: Int

    func validate() throws {
      _ = try RestoreProfile.select(target)
      guard schemaVersion == 1,
        nodeFormula.range(of: #"\Anode(@[0-9]+)?\z"#, options: .regularExpression) != nil,
        pythonFormula.range(of: #"\Apython@3\.[0-9]+\z"#, options: .regularExpression) != nil,
        pythonExecutable == pythonFormula.replacingOccurrences(of: "@", with: ""),
        (1...8).contains(rubyVersions.count), Set(rubyVersions).count == rubyVersions.count,
        certificateBundle.path == BaseCertificates.destination,
        (1...(16 << 20)).contains(certificateBundle.bytes),
        (1...2000).contains(certificateCount)
      else { throw MisoError.invalid("Invalid Base cleanup plan") }
      for version in rubyVersions { _ = try StableVersion(version) }
      try SafeFile.validateSHA256(certificateBundle.sha256)
    }
  }

  public struct Details: Codable {
    let plan: Plan
    let planSHA256: String
    let removedEntries: [String: Int]
    let payloadEntries: Int
    let detachedPayloadVerified: Bool
    let dependencyCheckPassed: Bool
    let linkageCheckPassed: Bool
    let rubyExtensionsVerified: Bool
    let pythonTrustVerified: Bool
  }

  public static func run(
    source: URL, plan planURL: URL, output: URL, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planHash = try SafeFile.sha256(planURL)
    let plan = try JSON.read(Plan.self, from: planURL)
    try plan.validate()
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-cleanup", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == plan.target else { throw MisoError.invalid("Cleanup target mismatch") }
      try journal.setMetadata("cleanupPlan", value: plan)
      let image = bundle.appendingPathComponent("disk.img")
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      let paths = ["opt/homebrew", "Users/\(username)/.rbenv", "Users/\(username)/actions-runner"]
      let caches = cachePaths(username: username)
      var identity: [UInt32] = []
      var removed: [String: Int] = [:]
      let payload = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        try guest.verifyControls(target: target)
        identity = [guest.account.uid, guest.account.gid]
        _ = try Artifacts.resolve(plan.certificateBundle, under: guest.data.root)
        try guest.run(
          "cleanup-brew",
          arguments: GuestExecution.brewArguments(["cleanup", "--prune=all"], username: username),
          capability: .brew, timeout: 300)
        try guest.run(
          "cleanup-npm",
          arguments: [
            "/usr/bin/env", "npm_config_offline=true", "npm_config_update_notifier=false",
            "npm_config_cache=/Users/\(username)/Library/Caches/npm",
            "PATH=/opt/homebrew/opt/\(plan.nodeFormula)/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "/opt/homebrew/opt/\(plan.nodeFormula)/bin/npm", "cache", "clean", "--force",
          ], capability: .base, timeout: 180)
        guard
          try guest.run(
            "cleanup-brew-missing",
            arguments: GuestExecution.brewArguments(["missing"], username: username),
            capability: .brew, timeout: 180
          ).isEmpty
        else { throw MisoError.invalid("Homebrew reports missing dependencies") }
        try guest.run(
          "cleanup-brew-linkage",
          arguments: GuestExecution.brewArguments(["linkage", "--test"], username: username),
          capability: .brew, timeout: 300)
        let count = try guest.run(
          "cleanup-python-trust",
          arguments: [
            "/opt/homebrew/opt/\(plan.pythonFormula)/bin/\(plan.pythonExecutable)", "-I", "-c",
            "import ssl; print(ssl.create_default_context().cert_store_stats()['x509_ca'])",
          ])
        guard Int(count) == plan.certificateCount else {
          throw MisoError.invalid("Final CA count differs")
        }
        for version in plan.rubyVersions {
          let actual = try guest.run(
            "cleanup-ruby-extensions",
            arguments: [
              "/Users/\(username)/.rbenv/versions/\(version)/bin/ruby",
              "-ropenssl", "-rpsych", "-rzlib", "-e", "puts RUBY_VERSION",
            ], capability: .ruby)
          guard actual == version else { throw MisoError.invalid("Final Ruby version differs") }
        }
        for path in caches {
          try journal.setMetadata("cleanupPath", value: path)
          var rootOwner: (uid: uid_t, gid: gid_t)?
          if path == "Users/\(username)/base-inputs", try guest.data.contains(path) {
            let info = try FileMetadata.inspect(guest.data.path(path))
            if info.st_uid == 0, info.st_gid == 0, info.st_mode == S_IFDIR | 0o755 {
              guard
                try FileManager.default.contentsOfDirectory(atPath: guest.data.path(path).path)
                  == ["git-credential-manager.rb"]
              else {
                throw MisoError.invalid("Unexpected legacy root-owned Base inputs")
              }
              rootOwner = (0, 0)
            }
          }
          removed[path] = try GuestCleanup.removeDirectory(
            path, volume: guest.data, uid: guest.account.uid, gid: guest.account.gid,
            rootOwner: rootOwner,
            cancellation: journal.cancellation)
        }
        _ = try Artifacts.resolve(plan.certificateBundle, under: guest.data.root)
        return try inventory(guest.data, paths: paths, account: guest.account, journal: journal)
      }
      try SafeFile.writeNew(
        JSON.encode(payload), to: output.appendingPathComponent("cleanup-payload.json"))
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let main = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "cleanup-audit",
          readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == identity,
          try inventory(data, paths: paths, account: account, journal: journal) == payload
        else { throw MisoError.invalid("Detached cleanup payload differs") }
        for path in caches where try data.contains(path) {
          throw MisoError.invalid("Guest cache remains: \(path)")
        }
        _ = try Artifacts.resolve(plan.certificateBundle, under: data.root)
      }
      guard try SafeFile.sha256(planURL) == planHash else {
        throw MisoError.invalid("Cleanup plan changed")
      }
      return Details(
        plan: plan, planSHA256: planHash, removedEntries: removed,
        payloadEntries: payload.values.reduce(0) { $0 + $1.count },
        detachedPayloadVerified: true, dependencyCheckPassed: true, linkageCheckPassed: true,
        rubyExtensionsVerified: true, pythonTrustVerified: true)
    }
  }

  static func cachePaths(username: String) -> [String] {
    [
      "Users/\(username)/base-inputs", "Users/\(username)/Library/Caches/Homebrew",
      "Users/\(username)/Library/Caches/npm", "Users/\(username)/Library/Caches/dotnet",
      "Users/\(username)/.rbenv/cache", "opt/homebrew/var/ruby-cache",
      "opt/homebrew/var/miso-root-certificates",
    ]
  }

  private static func inventory(
    _ data: GuestVolume, paths: [String], account: BaseImageStage.Account, journal: ExecutionJournal
  ) throws -> [String: [BaseInputArchive.Entry]] {
    try Dictionary(
      uniqueKeysWithValues: paths.map { path in
        let entries = try BaseFileTree.inventory(
          data, path: path, cancellation: journal.cancellation)
        try BaseFileTree.requireOwnership(
          data.path(path), entries: entries, uid: account.uid, gid: account.gid)
        return (path, entries)
      })
  }
}

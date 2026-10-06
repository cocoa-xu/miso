import Darwin
import Foundation

@MainActor
public enum BaseSecurity {
  public struct Plan: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let csrutilSHA256: String
    let tccdSHA256: String
    let tccSchemaSHA256: String
    let tccSchemaVersion: Int
    let tartVersion: String
    let preservedScreenSharingRequirement: Data?
    let captureReminder: BaseCaptureReminder.Policy?

    var agent: String { "opt/homebrew/Cellar/tart-guest-agent/\(tartVersion)/bin/tart-guest-agent" }

    func validate() throws {
      _ = try RestoreProfile.select(target)
      guard schemaVersion == 1, (1...100).contains(tccSchemaVersion),
        preservedScreenSharingRequirement == nil
          || preservedScreenSharingRequirement!.count <= 64 << 10
      else {
        throw MisoError.invalid("Invalid Base security plan")
      }
      for hash in [csrutilSHA256, tccdSHA256, tccSchemaSHA256] { try SafeFile.validateSHA256(hash) }
      try PackageRequest(name: "tart-guest-agent", version: tartVersion).validate()
      _ = try BaseTCC.grants(agent: agent)
      try captureReminder?.validate(target: target)
    }
  }

  public struct Details: Encodable {
    let plan: Plan
    let boot: BaseBootSecurity.Receipt
    let files: [ImageBundle.FileRecord]
    let tccRows: [Int]
    let detachedPayloadVerified: Bool
    let safariImplementationVerified: Bool
    let sipRuntimeVerified: Bool
    let tccRuntimeVerified: Bool
  }

  public static func run(
    source: URL, plan planURL: URL, boot: URL, material: URL,
    output: URL, username: String = "admin", cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planHash = try SafeFile.sha256(planURL)
    let plan = try JSON.read(Plan.self, from: planURL)
    try plan.validate()
    let inputs = try BaseBootSecurity.Inputs(boot: boot, material: material, target: plan.target)
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-security", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == plan.target else { throw MisoError.invalid("Base security target mismatch") }
      try journal.setMetadata("securityPlan", value: plan)
      let image = bundle.appendingPathComponent("disk.img")
      let schema = try inspectTarget(image, plan: plan, inputs: inputs, journal: journal)
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      let security = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        try guest.verifyControls(target: target)
        return try BuildProgress.run("Configure TCC and Safari remote automation") {
          try configure(plan, schema: schema, guest: guest)
        }
      }
      let write = try DiskImageSession(image: image, readOnly: false, journal: journal)
      let policy = try write.withAttachment { session in
        try BuildProgress.run("Configure SIP boot policy") {
          try BaseBootSecurity.apply(
            inputs, mounts: BaseBootSecurity.mounts(session, journal: journal, readOnly: false),
            journal: journal)
        }
      }
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let mounts = try BaseBootSecurity.mounts(session, journal: journal, readOnly: true)
        try BaseBootSecurity.verify(policy, mounts: mounts)
        let main = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "security-audit",
          readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        for record in security.files {
          let url = try Artifacts.resolve(
            record, under: data.root, cancellation: journal.cancellation)
          try verifyMetadata(
            url, account: account, userOwned: record.path.hasPrefix("Users/"),
            database: record.path.hasSuffix("TCC.db"))
        }
      }
      guard try SafeFile.sha256(planURL) == planHash else {
        throw MisoError.invalid("Base security plan changed")
      }
      try inputs.verifyJournal()
      return Details(
        plan: plan, boot: policy, files: security.files, tccRows: security.rows,
        detachedPayloadVerified: true, safariImplementationVerified: true,
        sipRuntimeVerified: false, tccRuntimeVerified: false)
    }
  }

  private static func inspectTarget(
    _ image: URL, plan: Plan, inputs: BaseBootSecurity.Inputs, journal: ExecutionJournal
  ) throws
    -> String
  {
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    return try audit.withAttachment { session in
      let main = try BaseImageStage.mainContainer(session)
      try BaseBootSecurity.preflight(
        inputs, mounts: BaseBootSecurity.mounts(session, journal: journal, readOnly: true))
      let system = try ImageMounts.mount(
        main.volume(role: "System"), session: session,
        journal: journal, name: "security-system", readOnly: true)
      let csrutil = try system.path("usr/bin/csrutil")
      let tccd = try system.path("System/Library/PrivateFrameworks/TCC.framework/Support/tccd")
      guard try SafeFile.sha256(csrutil) == plan.csrutilSHA256,
        try SafeFile.sha256(tccd) == plan.tccdSHA256
      else {
        throw MisoError.invalid("Target security implementation differs from plan")
      }
      if let reminder = plan.captureReminder {
        try reminder.verifyImplementation(system.path("usr/libexec/replayd"))
      }
      return try BaseTCC.schema(
        in: SafeFile.read(tccd, limit: 64 << 20),
        version: plan.tccSchemaVersion, sha256: plan.tccSchemaSHA256)
    }
  }

  private static func configure(_ plan: Plan, schema: String, guest: GuestExecution) throws -> (
    files: [ImageBundle.FileRecord], rows: [Int]
  ) {
    let home = "Users/" + guest.account.username
    _ = try SafeFile.openRegular(guest.data.path(plan.agent)).close()
    let grants = try BaseTCC.grants(agent: plan.agent)
    let probe = "private/tmp/miso-security-probe"
    guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath(),
      !(try guest.data.contains(probe))
    else {
      throw MisoError.invalid("Cannot prepare native security probe")
    }
    let probeURL = try guest.data.path(probe)
    try Artifacts.copy(
      binary, to: probeURL, maximumBytes: 128 << 20, cancellation: guest.journal.cancellation)
    guard chmod(probeURL.path, 0o555) == 0 else {
      throw MisoError.system("Set security probe mode", errno)
    }
    defer { _ = unlink(probeURL.path) }
    func probeState(_ name: String) throws -> [String: Any] {
      let output = try guest.run(name, arguments: ["/" + probe, "_security-probe"], timeout: 60)
      guard
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
        validProbeIdentity(result, home: "/" + home)
      else {
        throw MisoError.invalid("Unexpected target automation implementation")
      }
      return result
    }
    let before = try probeState("security-probe-before")
    guard before["safari_remote_automation"] as? Bool == false,
      let rights = before["rights"] as? [String: [String: Any]], rights.count == 3,
      !(try guest.data.contains("private/var/db/auth.db"))
    else { throw MisoError.invalid("Unexpected existing automation state") }
    let authorization = try RestoreInspection.plist(
      SafeFile.read(
        guest.root.appendingPathComponent("System/Library/Security/authorization.plist"),
        limit: 4 << 20))
    for (name, definition) in rights {
      let category = name == "com.apple.safaridriver.allow" ? "rights" : "rules"
      guard let entries = authorization[category] as? [String: [String: Any]],
        var original = entries[name]
      else {
        throw MisoError.invalid("Missing target authorization rule")
      }
      original.removeValue(forKey: "version")
      guard NSDictionary(dictionary: original).isEqual(to: definition) else {
        throw MisoError.invalid("Target authorization rule differs")
      }
    }
    var files: [String] = []
    var rows: [Int] = []
    for (prefix, userOwned) in [
      ("Library/Application Support/com.apple.TCC", false),
      (home + "/Library/Application Support/com.apple.TCC", true),
    ] {
      let uid = userOwned ? guest.account.uid : 0
      let gid = userOwned ? guest.account.gid : 0
      try guest.data.makeDirectories(prefix, uid: uid, gid: gid)
      let directory = try guest.data.directory(prefix).url
      guard chown(directory.path, uid, gid) == 0,
        chmod(directory.path, BaseTCC.directoryMode(userOwned: userOwned)) == 0
      else {
        throw MisoError.system("Set TCC directory metadata", errno)
      }
      let path = prefix + "/TCC.db"
      let url = try guest.data.path(path)
      for grant in grants {
        BuildProgress.write(
          "Configure \(userOwned ? "user" : "system") TCC: \(grant.service) for \(grant.client)")
      }
      rows.append(
        try BaseTCC.seed(
          url, schema: schema, version: plan.tccSchemaVersion, grants: grants,
          preservedRequirement: userOwned
            ? nil
            : plan.preservedScreenSharingRequirement
              ?? OfflineSessionState.screenSharingRequirement(for: plan.target)))
      guard chown(url.path, uid, gid) == 0, chmod(url.path, 0o600) == 0 else {
        throw MisoError.system("Set TCC database metadata", errno)
      }
      files.append(path)
    }
    if let reminder = plan.captureReminder {
      files.append(
        try BaseCaptureReminder.seed(
          reminder, data: guest.data, home: home, uid: guest.account.uid,
          gid: guest.account.gid, grants: grants))
    }
    let cookie = "private/var/db/com.apple.dt.automationmode/no-auth-required"
    guard !(try guest.data.contains(cookie)) else {
      throw MisoError.invalid("Automation cookie already exists")
    }
    try guest.data.makeDirectories((cookie as NSString).deletingLastPathComponent)
    try guest.data.write(cookie, data: Data())
    files.append(cookie)
    let safari = home + "/Library/WebDriver/com.apple.Safari.plist"
    guard !(try guest.data.contains(safari)) else {
      throw MisoError.invalid("Safari automation preferences already exist")
    }
    try guest.data.makeDirectories(
      (safari as NSString).deletingLastPathComponent, uid: guest.account.uid, gid: guest.account.gid
    )
    try guest.data.mergePlist(
      safari, values: ["AllowRemoteAutomation": true], uid: guest.account.uid,
      gid: guest.account.gid)
    guard try probeState("security-probe-after")["safari_remote_automation"] as? Bool == true else {
      throw MisoError.invalid("Target Safari did not accept offline preferences")
    }
    files.append(safari)
    let timeMachine = "Library/Preferences/com.apple.TimeMachine.plist"
    guard !(try guest.data.contains(timeMachine)) else {
      throw MisoError.invalid("Time Machine preferences already exist")
    }
    try guest.data.mergePlist(timeMachine, values: ["AutoBackup": false])
    files.append(timeMachine)
    return (
      try files.map { path in
        let url = try guest.data.path(path)
        try verifyMetadata(
          url, account: guest.account, userOwned: path.hasPrefix("Users/"),
          database: path.hasSuffix("TCC.db"))
        return try Artifacts.record(url, relativeTo: guest.data.root)
      }, rows
    )
  }

  private static func verifyMetadata(
    _ url: URL, account: BaseImageStage.Account, userOwned: Bool, database: Bool
  ) throws {
    if url.lastPathComponent == BaseCaptureReminder.filename {
      try BaseCaptureReminder.verify(url, uid: account.uid, gid: account.gid)
      return
    }
    if database {
      try BaseTCC.verifyDirectory(
        url.deletingLastPathComponent(), uid: userOwned ? account.uid : 0,
        gid: userOwned ? account.gid : 0, userOwned: userOwned)
    }
    let info = try FileMetadata.inspect(url)
    guard info.st_uid == (userOwned ? account.uid : 0),
      info.st_gid == (userOwned ? account.gid : 0),
      info.st_mode == S_IFREG | (database ? 0o600 : 0o644)
    else {
      throw MisoError.invalid("Base security file ownership or mode differs")
    }
  }

  static func validProbeIdentity(_ result: [String: Any], home: String) -> Bool {
    guard result["home"] as? String == home,
      let cookie = result["automation_cookie_path"] as? String, cookie.hasPrefix("/")
    else { return false }
    let absolute = "/" + cookie.drop(while: { $0 == "/" })
    return [
      "/var/db/com.apple.dt.automationmode/no-auth-required",
      "/private/var/db/com.apple.dt.automationmode/no-auth-required",
    ].contains(absolute)
  }
}

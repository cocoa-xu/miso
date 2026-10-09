import Darwin
import Foundation

enum OfflineSystemPolicy {
  struct Service: Codable {
    let label: String
    let state: SystemPolicy.ServiceState
    let domains: [String]
    let status: String
  }

  struct Preference: Codable {
    let path: String
    let key: String
    let value: Bool
  }

  struct Receipt: Codable {
    let policy: SystemPolicy
    let uid: UInt32
    let services: [Service]
    let preferences: [Preference]
    let spotlightPaths: [String]
    var runtimeVerified = false
  }

  static let receiptPath = "Library/Application Support/MISO/system-policy.json"

  static func apply(
    _ policy: SystemPolicy, system: GuestVolume, data: GuestVolume,
    account: BaseImageStage.Account, cancellation: CancellationToken?,
    systemOwner: (uid: uid_t, gid: gid_t) = (0, 0),
    additionalServices: [String: Set<String>] = [:]
  ) throws -> Receipt {
    try policy.validate()
    var inventory = try inventory(system: system, data: data, uid: account.uid)
    inventory.merge(additionalServices) { $0.union($1) }
    var services: [Service] = []
    var overrides: [String: [String: Bool]] = [:]
    for (label, state) in policy.resolvedServices.sorted(by: { $0.key < $1.key }) {
      try cancellation?.check()
      let domains = (inventory[label] ?? []).sorted()
      let status =
        state == .unchanged ? "unchanged" : domains.isEmpty ? "not-present" : "configured"
      services.append(Service(label: label, state: state, domains: domains, status: status))
      BuildProgress.write(
        "System service \(label): \(status)\(status == "configured" ? " (\(state.rawValue))" : "")")
      if status == "configured" {
        for domain in domains { overrides[domain, default: [:]][label] = state == .disabled }
      }
    }
    for domain in overrides.keys.sorted() {
      let suffix = domain == "system" ? "" : ".\(account.uid)"
      let path = "private/var/db/com.apple.xpc.launchd/disabled\(suffix).plist"
      let values = overrides[domain]!
      try data.mergePlist(
        path, values: values, uid: systemOwner.uid, gid: systemOwner.gid, mode: 0o600)
      let saved = try data.plist(path)
      for (label, disabled) in values where saved[label] as? Bool != disabled {
        throw MisoError.invalid("Service override readback differs: \(domain)/\(label)")
      }
    }
    let preferences = preferenceChanges(policy, username: account.username)
    for preference in preferences {
      try cancellation?.check()
      let userOwned = preference.path.hasPrefix("Users/")
      try data.mergePlist(
        preference.path, values: [preference.key: preference.value],
        uid: userOwned ? account.uid : systemOwner.uid,
        gid: userOwned ? account.gid : systemOwner.gid)
      guard try data.plist(preference.path)[preference.key] as? Bool == preference.value else {
        throw MisoError.invalid(
          "System preference readback differs: \(preference.path)/\(preference.key)")
      }
    }
    for (name, value) in policy.settings.sorted(by: { $0.key < $1.key }) {
      BuildProgress.write("System setting \(name): \(value)")
    }
    var spotlightPaths: [String] = []
    if let enabled = policy.settings["spotlightIndexing"] {
      for (_, directory) in BaseSystemSettings.spotlightStores {
        let path = directory + "/VolumeConfiguration.plist"
        guard try data.contains(path) else {
          throw MisoError.invalid("Prepared Base Spotlight configuration is missing: \(path)")
        }
        var plist = try data.plist(path)
        guard var stores = plist["Stores"] as? [String: [String: Any]], !stores.isEmpty else {
          throw MisoError.invalid("Missing Spotlight stores: \(path)")
        }
        for name in stores.keys {
          stores[name]!["PolicyLevel"] =
            enabled
            ? "kMDConfigSearchLevelReadWrite" : "kMDConfigSearchLevelFSSearchOnly"
          stores[name]!["PolicyDate"] = Date()
        }
        plist["Stores"] = stores
        try data.write(
          path,
          data: PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0),
          uid: systemOwner.uid, gid: systemOwner.gid, mode: 0o600)
        spotlightPaths.append(path)
      }
    }
    let receipt = Receipt(
      policy: policy, uid: account.uid, services: services, preferences: preferences,
      spotlightPaths: spotlightPaths)
    try data.write(
      receiptPath, data: JSON.encode(receipt), uid: systemOwner.uid, gid: systemOwner.gid)
    return receipt
  }

  static func inventory(system: GuestVolume, data: GuestVolume, uid: UInt32) throws
    -> [String: Set<String>]
  {
    try inventory(
      roots: [
        (system, "System/Library"), (data, "Library"), (data, "Library/Apple/System/Library"),
      ],
      uid: uid)
  }

  private static func inventory(roots: [(GuestVolume, String)], uid: UInt32) throws
    -> [String: Set<String>]
  {
    var result: [String: Set<String>] = [:]
    for (volume, root) in roots {
      for (kind, domain) in [("LaunchDaemons", "system"), ("LaunchAgents", "gui/\(uid)")] {
        let path = root + "/" + kind
        guard try volume.contains(path) else { continue }
        let directory = try volume.directory(path).url
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        where name.hasSuffix(".plist") {
          let url = directory.appendingPathComponent(name)
          guard try FileMetadata.inspect(url).st_mode & S_IFMT == S_IFREG else { continue }
          let plist = try volume.plist(path + "/" + name)
          if plist["Label"] == nil && plist["Program"] == nil && plist["ProgramArguments"] == nil {
            continue
          }
          guard let label = plist["Label"] as? String, !label.isEmpty else {
            throw MisoError.invalid("Missing launchd Label: \(path)/\(name)")
          }
          result[label, default: []].insert(domain)
        }
      }
    }
    return result
  }

  static func cryptexInventory(preboot: GuestVolume, uid: UInt32, journal: ExecutionJournal) throws
    -> [String: Set<String>]
  {
    var result: [String: Set<String>] = [:]
    let groups = try FileManager.default.contentsOfDirectory(atPath: preboot.root.path)
      .filter { UUID(uuidString: $0) != nil }
    for kind in ["os", "app"] {
      var images: [URL] = []
      for group in groups {
        let candidate = preboot.root.appendingPathComponent("\(group)/cryptex1/current/\(kind).dmg")
          .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(preboot.root.path + "/") else {
          throw MisoError.invalid("Service catalog Cryptex escapes Preboot")
        }
        if FileManager.default.fileExists(atPath: candidate.path) { images.append(candidate) }
      }
      guard images.count <= 1 else { throw MisoError.invalid("Ambiguous \(kind) service Cryptex") }
      guard let image = images.first else { continue }
      let session = try DiskImageSession(
        image: image, readOnly: true, journal: journal, forceReadOnlyDetach: true)
      let mount = journal.output.appendingPathComponent("policy-cryptex-\(kind)")
      let services = try session.withAttachment(requireGPT: false, mountPoint: mount) { _ in
        let volume = try GuestVolume(mount)
        return try inventory(roots: [(volume, "System/Library"), (volume, "Library")], uid: uid)
      }
      result.merge(services) { $0.union($1) }
    }
    return result
  }

  static func preferenceChanges(_ policy: SystemPolicy, username: String) -> [Preference] {
    var result: [Preference] = []
    func set(_ domain: String, _ key: String, _ value: Bool, user: Bool = false) {
      result.append(
        Preference(
          path: (user ? "Users/\(username)/" : "") + "Library/Preferences/\(domain).plist",
          key: key, value: value))
    }
    if let enabled = policy.settings["automaticOSUpdates"] {
      set("com.apple.SoftwareUpdate", "AutomaticDownload", enabled)
      set("com.apple.SoftwareUpdate", "AutomaticallyInstallMacOSUpdates", enabled)
    }
    if let enabled = policy.settings["automaticAppUpdates"] {
      set("com.apple.SoftwareUpdate", "AutomaticallyInstallAppUpdates", enabled)
      for user in [false, true] {
        for key in ["AutoUpdate", "AutoDownload"] {
          set("com.apple.commerce", key, enabled, user: user)
        }
      }
    }
    if let enabled = policy.settings["securityDataUpdates"] {
      set("com.apple.SoftwareUpdate", "ConfigDataInstall", enabled)
      set("com.apple.SoftwareUpdate", "CriticalUpdateInstall", enabled)
    }
    if let enabled = policy.settings["automaticBackups"] {
      set("com.apple.TimeMachine", "AutoBackup", enabled)
    }
    if let enabled = policy.settings["sessionRestore"] {
      set("com.apple.loginwindow", "TALLogoutSavesState", enabled, user: true)
    }
    if let enabled = policy.settings["reduceMotion"] {
      set("com.apple.universalaccess", "reduceMotion", enabled, user: true)
      set("com.apple.Accessibility", "ReduceMotionEnabled", enabled, user: true)
    }
    if let enabled = policy.settings["reduceTransparency"] {
      set("com.apple.universalaccess", "reduceTransparency", enabled, user: true)
    }
    if let state = policy.features["telemetryUpload"], state != .unchanged {
      set("com.apple.SubmitDiagInfo", "AutoSubmit", state == .enabled)
      set("com.apple.SubmitDiagInfo", "ThirdPartyDataSubmit", state == .enabled)
      for key in ["AutoSubmit", "ThirdPartyDataSubmit"] {
        result.append(
          Preference(
            path: "Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist",
            key: key, value: state == .enabled))
      }
    }
    return result
  }
}

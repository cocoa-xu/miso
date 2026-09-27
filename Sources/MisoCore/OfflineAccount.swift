import Darwin
import Foundation

enum OfflineAccount {
  static let node = "private/var/db/dslocal/nodes/Default/"
  static let privacyPolicy = "Library/Application Support/com.apple.TCC/SiteOverrides.plist"

  struct Receipt: Codable, Sendable {
    let username: String
    let user: UUID
    let timeZone: String
    let automaticLogin: Bool
    let remoteLogin: Bool
    let screenSharing: Bool
    let secureTokenCreated: Bool
    let volumeOwnershipCreated: Bool
  }

  static func record(configuration: ImageConfiguration, identifier: UUID) throws -> [String: Any] {
    try configuration.validate()
    return [
      "name": [configuration.username], "realname": [configuration.fullName],
      "uid": ["501"], "gid": ["20"], "home": ["/Users/" + configuration.username],
      "shell": ["/bin/zsh"], "generateduid": [identifier.uuidString], "passwd": ["********"],
      "authentication_authority": [";ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>"],
      "ShadowHashData": [try configuration.shadowHash()],
      "_writers_passwd": [configuration.username],
    ]
  }

  static func verifyPassword(_ blob: Data, password: String) throws -> Bool {
    let plist = try RestoreInspection.plist(blob)
    guard let hash = plist["SALTED-SHA512-PBKDF2"] as? [String: Any],
      let salt = hash["salt"] as? Data, let expected = hash["entropy"] as? Data,
      hash["iterations"] as? Int == 200_000, expected.count == 128
    else { throw MisoError.invalid("Invalid account password hash") }
    let actual = try ImageConfiguration.derivePassword(password, salt: salt)
    return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  static func loginPassword(_ password: String) -> Data {
    let key: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xA1, 0xB9, 0xA3, 0xB9, 0x1F]
    var bytes = Array(password.utf8) + [0]
    bytes += [UInt8](repeating: 0, count: (12 - bytes.count % 12) % 12)
    return Data(bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] })
  }

  static func vncPassword(_ password: String) -> Data {
    let bytes = Array(password.utf8)
    let padded = bytes + [UInt8](repeating: 0, count: 16 - bytes.count)
    return Data(
      padded.enumerated().map {
        String(format: "%02X", $0.element ^ UInt8((23 + $0.offset * 29) & 255))
      }.joined().utf8)
  }

  static func setupPreferences(_ profile: RestoreProfile) -> [String: Any] {
    var values: [String: Any] = [
      "LastSeenBuddyBuildVersion": profile.release.build,
      "MiniBuddyLaunchReason": 0, "selectedFDEEscrowType": "DeclinedFDE",
    ]
    for key in profile.setupCompletedKeys { values[key] = true }
    for key in profile.setupVersionKeys { values[key] = profile.release.version }
    return values
  }

  static func apply(
    system: GuestVolume, data: GuestVolume, profile: RestoreProfile,
    configuration: ImageConfiguration, cancellation: CancellationToken
  ) throws -> Receipt {
    try configuration.validate()
    guard !configuration.installRosetta else {
      throw MisoError.unsupported("offline macOS Rosetta installation")
    }
    let zones = try system.path("usr/share/zoneinfo.default")
    let zone = try system.path(
      "usr/share/zoneinfo.default/" + configuration.timeZone, allowLeafLink: true
    ).resolvingSymlinksInPath()
    guard zone.path.hasPrefix(zones.path + "/"),
      try FileMetadata.inspect(zone).st_dev == system.device
    else {
      throw MisoError.invalid("Time zone resolves outside the target System")
    }
    try SafeFile.openRegular(zone).close()
    let userPath = node + "users/" + configuration.username + ".plist"
    let homePath = "Users/" + configuration.username
    let marker = "private/var/db/.AppleSetupDone"
    for relative in [userPath, homePath, marker]
      + (configuration.screenSharing ? [privacyPolicy] : [])
    {
      guard try !data.contains(relative) else {
        throw MisoError.invalid("Refusing to replace existing setup state: \(relative)")
      }
    }
    for name in try FileManager.default.contentsOfDirectory(atPath: data.path(node + "users").path)
    {
      let user = try data.plist(node + "users/" + name)
      guard !(user["uid"] as? [String] ?? []).contains("501") else {
        throw MisoError.invalid("UID 501 is already occupied")
      }
    }
    var admin = try data.plist(node + "groups/admin.plist")
    guard (admin["name"] as? [String] ?? []).contains("admin"), admin["gid"] as? [String] == ["80"]
    else {
      throw MisoError.invalid("Invalid administrator group")
    }
    let identifier = UUID()
    let user = try record(configuration: configuration, identifier: identifier)
    admin["users"] = Array(Set((admin["users"] as? [String] ?? []) + [configuration.username]))
      .sorted()
    admin["groupmembers"] = Array(
      Set((admin["groupmembers"] as? [String] ?? []) + [identifier.uuidString])
    ).sorted()
    let home = try data.path(homePath)
    guard mkdir(home.path, 0o700) == 0 else { throw MisoError.system("Create guest home", errno) }
    for template in ["Non_localized", "English.lproj"] {
      try FileMetadata.copyTree(
        data.directory("Library/User Template/" + template), to: data.directory(homePath),
        cancellation: cancellation)
    }
    try FileMetadata.walk(home) { relative, _ in
      try cancellation.check()
      guard lchown(home.appendingPathComponent(relative).path, 501, 20) == 0 else {
        throw MisoError.system("Set guest home ownership", errno)
      }
    }
    guard chown(home.path, 501, 20) == 0, chmod(home.path, 0o700) == 0 else {
      throw MisoError.system("Set guest home root metadata", errno)
    }
    try data.mergePlist(userPath, values: user, mode: 0o600)
    try data.mergePlist(node + "groups/admin.plist", values: admin, mode: 0o600)
    let preferences = homePath + "/Library/Preferences/"
    let setup = setupPreferences(profile)
    try data.mergePlist("Library/Preferences/com.apple.SetupAssistant.plist", values: setup)
    try data.mergePlist(
      preferences + "com.apple.SetupAssistant.plist", values: setup, uid: 501, gid: 20, mode: 0o600)
    try data.mergePlist(
      "Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist",
      values: ["AutoSubmit": false, "ThirdPartyDataSubmit": false])
    try data.mergePlist(
      "Library/Preferences/com.apple.timezone.auto.plist", values: ["Active": false])
    let locale: [String: Any] = ["AppleLanguages": ["en-US"], "AppleLocale": "en_US"]
    try data.mergePlist("Library/Preferences/.GlobalPreferences.plist", values: locale)
    try data.mergePlist(
      preferences + ".GlobalPreferences.plist", values: locale, uid: 501, gid: 20, mode: 0o600)
    let localtime = try data.path("private/etc/localtime", allowLeafLink: true)
    var info = stat()
    if lstat(localtime.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFLNK, unlink(localtime.path) == 0 else {
        throw MisoError.invalid("Expected a replaceable localtime symlink")
      }
    } else if errno != ENOENT {
      throw MisoError.system("Inspect localtime", errno)
    }
    guard symlink("/var/db/timezone/zoneinfo/" + configuration.timeZone, localtime.path) == 0 else {
      throw MisoError.system("Set guest time zone", errno)
    }
    if configuration.automaticLogin {
      try data.write(
        "private/etc/kcpassword", data: loginPassword(configuration.password), mode: 0o600)
      try data.mergePlist(
        "Library/Preferences/com.apple.loginwindow.plist",
        values: ["autoLoginUser": configuration.username, "autoLoginUserUID": 501])
    }
    try configureRemote(data: data, configuration: configuration, user: identifier)
    if configuration.passwordlessSudo {
      try data.write(
        "private/etc/sudoers.d/ci-user",
        data: Data((configuration.username + " ALL=(ALL) NOPASSWD: ALL\n").utf8), mode: 0o440)
    }
    try configurePreferences(data: data, configuration: configuration, preferences: preferences)
    try LinuxTranslation.configure(
      data: data, profile: profile, include: configuration.includeLinuxTranslation)
    try data.mergePlist(
      "private/var/db/.GKRearmTimer", values: ["event": "masterswitch", "timestamp": Date()])
    let saved = try data.plist(userPath)
    guard let hash = (saved["ShadowHashData"] as? [Data])?.first,
      try verifyPassword(hash, password: configuration.password),
      try !verifyPassword(hash, password: configuration.password + "-wrong")
    else { throw MisoError.invalid("Saved account password failed verification") }
    try data.write(marker, data: Data())
    return Receipt(
      username: configuration.username, user: identifier, timeZone: configuration.timeZone,
      automaticLogin: configuration.automaticLogin, remoteLogin: configuration.remoteLogin,
      screenSharing: configuration.screenSharing, secureTokenCreated: false,
      volumeOwnershipCreated: false)
  }

  static func configureRemote(data: GuestVolume, configuration: ImageConfiguration, user: UUID)
    throws
  {
    try data.mergePlist(
      "private/var/db/com.apple.xpc.launchd/disabled.plist",
      values: [
        "com.openssh.sshd": !configuration.remoteLogin,
        "com.apple.screensharing": !configuration.screenSharing,
      ],
      mode: 0o600)
    for (enabled, name) in [
      (configuration.remoteLogin, "com.apple.access_ssh"),
      (configuration.screenSharing, "com.apple.access_screensharing"),
    ] where enabled {
      let path = node + "groups/" + name + ".plist"
      var group = try data.plist(path)
      guard (group["name"] as? [String] ?? []).contains(name) else {
        throw MisoError.invalid("Unexpected remote access group")
      }
      group["users"] = [configuration.username]
      group["groupmembers"] = [user.uuidString]
      group.removeValue(forKey: "nestedgroups")
      try data.write(
        path,
        data: PropertyListSerialization.data(fromPropertyList: group, format: .binary, options: 0),
        mode: 0o600)
    }
    if configuration.screenSharing {
      try data.mergePlist(
        "Library/Preferences/com.apple.RemoteManagement.plist",
        values: ["ScreenSharingReqPermEnabled": false, "VNCLegacyConnectionsEnabled": true])
      try data.write(
        "Library/Preferences/com.apple.VNCSettings.txt",
        data: vncPassword(configuration.vncPassword), mode: 0o600)
      let policy = Dictionary(
        uniqueKeysWithValues: ["ScreenCapture", "PostEvent"].map {
          (
            $0,
            [
              [
                "Allowed": true, "Identifier": "com.apple.screensharing.agent",
                "IdentifierType": "bundleID",
                "CodeRequirement": "identifier \"com.apple.screensharing.agent\" and anchor apple",
              ]
            ] as [[String: Any]]
          )
        })
      try data.mergePlist(privacyPolicy, values: ["Services": policy])
      let parent = try data.path(privacyPolicy).deletingLastPathComponent()
      guard chown(parent.path, 0, 0) == 0, chmod(parent.path, 0o755) == 0 else {
        throw MisoError.system("Set guest screen-sharing policy metadata", errno)
      }
    }
  }

  static func configurePreferences(
    data: GuestVolume, configuration: ImageConfiguration, preferences: String
  ) throws {
    try data.mergePlist(
      "private/var/db/SystemPolicyConfiguration/SystemPolicy-prefs.plist",
      values: ["enabled": configuration.gatekeeperEnabled ? "yes" : "no"])
    if configuration.disableSleep {
      try data.mergePlist(
        "Library/Preferences/com.apple.PowerManagement.plist",
        values: [
          "AC Power": ["Disk Sleep Timer": 0, "Display Sleep Timer": 0, "System Sleep Timer": 0]
        ])
    }
    guard configuration.desktopDefaults else { return }
    try data.mergePlist(
      "Library/Preferences/com.apple.screensaver.plist", values: ["loginWindowIdleTime": 0])
    let settings: [(String, [String: Any])] = [
      ("com.apple.screensaver", ["idleTime": 0]),
      (".GlobalPreferences", ["AppleKeyboardUIMode": 3, "NSQuitAlwaysKeepsWindows": false]),
      (
        "com.apple.Accessibility",
        ["AccessibilityEnabled": false, "ApplicationAccessibilityEnabled": false]
      ),
      ("com.apple.universalaccess", ["voiceOverOnOffKey": false]),
      ("com.apple.WindowManager", ["StandardHideWidgets": true, "StageManagerHideWidgets": true]),
      (
        "com.apple.loginwindow",
        ["TALAppsToRelaunchAtLogin": [String](), "TALLogoutSavesState": false]
      ),
      (
        "com.apple.HIToolbox",
        [
          "AppleEnabledInputSources": [
            [
              "InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": 0,
              "KeyboardLayout Name": "U.S.",
            ]
          ]
        ]
      ),
    ]
    for (name, values) in settings {
      try data.mergePlist(
        preferences + name + ".plist", values: values, uid: 501, gid: 20, mode: 0o600)
    }
  }
}

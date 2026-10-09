import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func systemPolicyVerificationUsesEffectiveDiagnosticConsentAfterMigration() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  let path = SystemPolicyVerification.diagnosticHistory
  try volume.mergePlist(
    path, values: ["ThirdPartyDataSubmit": false], uid: getuid(), gid: getgid())
  let preferences = [
    OfflineSystemPolicy.Preference(path: path, key: "AutoSubmit", value: false),
    OfflineSystemPolicy.Preference(path: path, key: "ThirdPartyDataSubmit", value: false),
  ]
  let disabled = try SystemPolicyVerification.observePreferences(
    preferences, root: temporary.url, autoSubmit: false)
  #expect(disabled[0].stored == nil && disabled[0].actual == false)
  #expect(disabled.allSatisfy { $0.actual == $0.expected })
  for consent in [true, nil] as [Bool?] {
    let observations = try SystemPolicyVerification.observePreferences(
      preferences, root: temporary.url, autoSubmit: consent)
    #expect(observations[0].actual != observations[0].expected)
  }
  try volume.mergePlist(
    path, values: ["ThirdPartyDataSubmit": true], uid: getuid(), gid: getgid())
  let changed = try SystemPolicyVerification.observePreferences(
    preferences, root: temporary.url, autoSubmit: false)
  #expect(changed[1].actual != changed[1].expected)
}

@Test func systemPolicyVerificationDistinguishesLoadedIdleAndRunningServices() throws {
  let state = """
    \tservices = {
    \t\t123 - com.test.running
    \t\t0 0 com.test.idle
    \t\t- 0 com.test.unloaded
    \t}
    \tdisabled services = {
    \t\t"com.test.running" => true
    \t}
    """
  #expect(
    try SystemPolicyVerification.serviceProcesses(state) == [
      "com.test.running": 123, "com.test.idle": 0, "com.test.unloaded": 0,
    ])
  #expect(throws: MisoError.self) {
    try SystemPolicyVerification.serviceProcesses("unrecognized output")
  }
  #expect(throws: MisoError.self) {
    try SystemPolicyVerification.serviceProcesses(
      state.replacingOccurrences(of: "123 -", with: "unknown -"))
  }
  #expect(
    SystemPolicyVerification.parseOverrides(
      """
      \t"com.test.running" => true
      \t"com.test.idle" => enabled
      \t"com.test.unloaded" => disabled
      \t"com.test.invalid" => maybe
      """) == ["com.test.running": true, "com.test.idle": false, "com.test.unloaded": true])
}

@Test func slimSystemPolicyKeepsDevelopmentSecurityAndLocalDiagnostics() throws {
  let policy = XcodeBuildProfile.slim.system
  let disabled = policy.resolvedServices.filter { $0.value == .disabled }
  for label in [
    "com.apple.ReportCrash", "com.apple.spindump", "com.apple.logd", "com.apple.analyticsd",
    "com.apple.Siri.agent",
    "com.apple.previewsd", "com.apple.dt.AutomationModeUI", "com.apple.dt.automationmode-writer",
    "com.apple.webinspectord", "com.apple.mobileassetd", "com.apple.security.cryptexd",
    "com.apple.securityd", "com.apple.trustd", "com.apple.authd", "com.apple.akd",
    "com.openssh.sshd", "com.apple.screensharing", "com.apple.softwareupdated",
  ] {
    #expect(disabled[label] == nil)
  }
  #expect(policy.settings["securityDataUpdates"] == true)
  #expect(policy.settings["automaticOSUpdates"] == false)
  #expect(policy.settings["automaticAppUpdates"] == false)
  #expect(policy.settings["reduceMotion"] == nil && policy.settings["reduceTransparency"] == nil)
  let labels = SystemServiceCatalog.features.values.flatMap { $0 }
  #expect(Set(labels).count == labels.count)
  #expect(XcodeBuildProfile().system.isEmpty)
}

@Test func systemYAMLOverridesPresetPerFeatureServiceAndSetting() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let url = directory.url.appendingPathComponent("profile.yaml")
  try SafeFile.writeNew(
    Data(
      """
      preset: slim
      system:
        features:
          messages: unchanged
        services:
          com.apple.photoanalysisd: unchanged
          com.example.service: disabled
        settings:
          sessionRestore: true
      """.utf8), to: url)
  let profile = try XcodeBuildProfile.read(url)
  #expect(profile.platforms == [.iOS, .watchOS] && profile.trimIntel)
  #expect(profile.system.resolvedServices["com.apple.imagent"] == .unchanged)
  #expect(profile.system.resolvedServices["com.apple.photoanalysisd"] == .unchanged)
  #expect(profile.system.resolvedServices["com.apple.mediaanalysisd"] == .disabled)
  #expect(profile.system.services["com.example.service"] == .disabled)
  #expect(profile.system.settings["sessionRestore"] == true)
  #expect(profile.system.settings["automaticOSUpdates"] == false)
  #expect(try JSONDecoder().decode(XcodeBuildProfile.self, from: JSON.encode(profile)) == profile)
  for invalid in [
    "system: {setting: {reduceMotion: true}}",
    "system: {settings: {reduceMotion: true, reduceMotion: false}}",
    "system: {features: {cloudSyncc: disabled}}",
    "system: {services: {com.apple.test: false}}",
    "system: {services: {'../host': disabled}}",
    "system: {settings: {reduceMotion: perhaps}}",
    "system: {settings: {unknown: true}}",
  ] {
    try SafeFile.replace(Data(invalid.utf8), at: url)
    #expect(throws: (any Error).self) { try XcodeBuildProfile.read(url) }
  }
}

@Test func offlineServiceOverridesUseTargetLabelsAndDomainsAndPreserveOtherSettings() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let systemURL = temporary.url.appendingPathComponent("system")
  let dataURL = temporary.url.appendingPathComponent("data")
  try SafeFile.makeDirectory(systemURL)
  try SafeFile.makeDirectory(dataURL)
  let system = try GuestVolume(systemURL)
  let data = try GuestVolume(dataURL)
  let user = getuid()
  let group = getgid()
  for (volume, path, values) in [
    (system, "System/Library/LaunchDaemons/unrelated-filename.plist", ["Label": "com.test.shared"]),
    (system, "System/Library/LaunchAgents/user.plist", ["Label": "com.test.shared"]),
    (data, "Library/LaunchDaemons/other.plist", ["Label": "com.test.enable"]),
    (system, "System/Library/LaunchDaemons/com.apple.jetsamproperties.Mac.plist", ["Version": "1"]),
  ] {
    try volume.mergePlist(path, values: values, uid: user, gid: group)
  }
  let source = try SafeFile.read(
    system.path("System/Library/LaunchDaemons/unrelated-filename.plist"), limit: 1 << 20)
  try data.mergePlist(
    "private/var/db/dslocal/nodes/Default/users/admin.plist",
    values: ["uid": [String(user)], "gid": [String(group)], "home": ["/Users/admin"]],
    uid: user, gid: group)
  let override = "private/var/db/com.apple.xpc.launchd/disabled.plist"
  try data.mergePlist(
    override, values: ["com.openssh.sshd": false, "com.test.enable": true], uid: user, gid: group)
  try data.mergePlist(
    "Library/Preferences/com.apple.SoftwareUpdate.plist", values: ["Existing": "preserved"],
    uid: user, gid: group)
  let spotlightPaths = [
    ".Spotlight-V100/VolumeConfiguration.plist",
    "private/var/db/Spotlight-V100/BootVolume/VolumeConfiguration.plist",
    "private/var/db/Spotlight-V100/Preboot/VolumeConfiguration.plist",
  ]
  for path in spotlightPaths {
    try data.mergePlist(
      path, values: ["Stores": ["fixture": ["PolicyLevel": "kMDConfigSearchLevelReadWrite"]]],
      uid: user, gid: group)
  }
  var policy = SystemPolicy()
  policy.services = [
    "com.test.shared": .disabled, "com.test.enable": .enabled, "com.test.missing": .disabled,
  ]
  policy.settings = [
    "automaticOSUpdates": false, "securityDataUpdates": true, "spotlightIndexing": false,
  ]
  let receipt = try OfflineSystemPolicy.apply(
    policy, system: system, data: data,
    account: BaseImageStage.Account("admin", data: data), cancellation: nil,
    systemOwner: (user, group))
  #expect(receipt.services.first { $0.label == "com.test.missing" }?.status == "not-present")
  #expect(
    receipt.services.first { $0.label == "com.test.shared" }?.domains == ["gui/\(user)", "system"])
  let saved = try data.plist(override)
  #expect(saved["com.test.shared"] as? Bool == true && saved["com.test.enable"] as? Bool == false)
  #expect(saved["com.openssh.sshd"] as? Bool == false && saved["com.test.missing"] == nil)
  #expect(
    try data.plist("private/var/db/com.apple.xpc.launchd/disabled.\(user).plist")["com.test.shared"]
      as? Bool == true)
  #expect(
    try data.plist("Library/Preferences/com.apple.SoftwareUpdate.plist")["Existing"] as? String
      == "preserved")
  #expect(
    try SafeFile.read(
      system.path("System/Library/LaunchDaemons/unrelated-filename.plist"), limit: 1 << 20)
      == source)
  #expect(!receipt.runtimeVerified)
  #expect(Set(receipt.spotlightPaths) == Set(spotlightPaths))
  for path in spotlightPaths {
    let stores = try data.plist(path)["Stores"] as? [String: [String: Any]]
    #expect(stores?["fixture"]?["PolicyLevel"] as? String == "kMDConfigSearchLevelFSSearchOnly")
  }
  try system.mergePlist(
    "System/Library/LaunchDaemons/malformed.plist", values: ["Program": "/usr/libexec/example"],
    uid: user, gid: group)
  #expect(throws: MisoError.self) {
    try OfflineSystemPolicy.inventory(system: system, data: data, uid: user)
  }
}

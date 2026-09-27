import Foundation
import Testing

@testable import MisoCore

@Test func tartServicesPreserveVendorCommandAndUseSupervisedRestart() throws {
  for role in ["daemon", "agent"] {
    let original: [String: Any] = [
      "Label": "dev.macos-image.tart-guest-" + role,
      "ProgramArguments": ["/opt/homebrew/bin/tart-guest-agent", "--run-" + role],
      "Disabled": true, "RunAtLoad": true, "KeepAlive": true,
    ]
    let updated = try BaseSystemSettings.supervisedService(original, role: role)
    #expect(updated["Disabled"] == nil)
    #expect(updated["RunAtLoad"] as? Bool == true)
    #expect(updated["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    #expect(
      updated["ProgramArguments"] as? [String] == [
        "/bin/sh", "/usr/local/libexec/miso-tart-supervisor",
        "/opt/homebrew/bin/tart-guest-agent", "--run-" + role,
      ])
    #expect(throws: (any Error).self) {
      try BaseSystemSettings.supervisedService(updated, role: role)
    }
  }
  #expect(throws: (any Error).self) { try BaseSystemSettings.supervisedService([:], role: "agent") }
}

@Test func spotlightSettingsBindTargetVolumesAndOrderedDates() throws {
  let plan = BaseSystemSettings.Plan(
    schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"),
    mdsSHA256: String(repeating: "a", count: 64), indexVersion: 100, tartVersion: "0.15.0")
  let volume = UUID()
  let store = UUID()
  let created = Date(timeIntervalSince1970: 10)
  let modified = Date(timeIntervalSince1970: 20)
  let result = try BaseSystemSettings.spotlight(
    plan, volume: volume, store: store, created: created, modified: modified)
  #expect(result["ConfigurationVolumeUUID"] as? String == volume.uuidString)
  let stores = try #require(result["Stores"] as? [String: [String: Any]])
  #expect(Set(stores.keys) == [store.uuidString])
  #expect(stores[store.uuidString]?["IndexVersion"] as? Int == 100)
  #expect(stores[store.uuidString]?["PolicyLevel"] as? String == "kMDConfigSearchLevelFSSearchOnly")
  #expect(stores[store.uuidString]?["PolicyVersion"] as? String == "Version 26.6.2 (Build 25G83)")
  #expect(throws: (any Error).self) {
    try BaseSystemSettings.spotlight(
      plan, volume: volume, store: store, created: created, modified: created)
  }
}

@Test func tartSupervisorPreservesNormalChildExit() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let script = temporary.url.appendingPathComponent("supervisor.sh")
  try SafeFile.writeNew(Data(BaseSystemSettings.supervisor.utf8), to: script)
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("run"), operation: "test-supervisor")
  try journal.run("syntax", NativeCommand("/bin/sh", arguments: ["-n", script.path]))
  try journal.run(
    "child-exit", NativeCommand("/bin/sh", arguments: [script.path, "/bin/sh", "-c", "exit 17"]),
    expectedExitCodes: [17])
  try journal.run(
    "missing-child", NativeCommand("/bin/sh", arguments: [script.path]), expectedExitCodes: [64])
}

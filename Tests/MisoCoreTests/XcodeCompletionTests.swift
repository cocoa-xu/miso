import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func xcodeCompletionRequiresEveryConfiguredLayerWithoutDuplicateOrBootedStages() throws {
  let configuration = XcodeConfiguration()
  let stages = XcodeCompletion.requiredStages(configuration).sorted()
  let original: [String: Any] = [
    "base_complete": true, "construction_vm_started": false, "runtime_verified": false,
    "xcode_complete": false, "xcode_stages": stages,
  ]
  func check(_ manifest: [String: Any], finalized: Bool = false) throws {
    try XcodeCompletion.requireStages(
      JSONSerialization.data(withJSONObject: manifest), configuration: configuration,
      finalized: finalized)
  }
  try check(original)
  var refreshed = original
  refreshed["xcode_stages"] = stages + ["xcode-homebrew"]
  try check(refreshed)
  refreshed["xcode_stages"] = stages + ["xcode-homebrew", "xcode-homebrew"]
  #expect(throws: MisoError.self) { try check(refreshed) }
  #expect(throws: MisoError.self) { try check(original, finalized: true) }
  for missing in stages {
    var value = original
    value["xcode_stages"] = stages.filter { $0 != missing }
    #expect(throws: MisoError.self) { try check(value) }
  }
  for additions in [[stages[0]], ["xcode-unknown"]] {
    var value = original
    value["xcode_stages"] = stages + additions
    #expect(throws: MisoError.self) { try check(value) }
  }
  for key in ["base_complete", "construction_vm_started", "runtime_verified", "xcode_complete"] {
    var value = original
    value[key] = !(original[key] as! Bool)
    #expect(throws: MisoError.self) { try check(value) }
  }
  var finalized = original
  finalized["xcode_stages"] = stages + ["xcode-finalize"]
  try check(finalized, finalized: true)
  #expect(throws: MisoError.self) { try check(finalized) }
}

@Test func developerDisksRejectAnotherPlatformBuildOrMissingRestoreMetadata() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let data = try GuestVolume(temporary.url)
  let info: [String: Any] = [
    "Platform": "iOS", "ProductBuildVersion": "27A266a", "Variant": "Public",
    "BuildVersion": "1741",
  ]
  try data.mergePlist("version.plist", values: info, uid: getuid(), gid: getgid())
  #expect(throws: (any Error).self) {
    try XcodeCompletion.validateDeveloperDisk(data, platform: "iOS", configuration: .init())
  }
  try data.mergePlist(
    "Restore/BuildManifest.plist", values: ["ProductVersion": "27.0"], uid: getuid(), gid: getgid())
  try data.mergePlist(
    "Restore/Restore.plist", values: ["ProductBuildVersion": "27A266a"], uid: getuid(),
    gid: getgid())
  try XcodeCompletion.validateDeveloperDisk(data, platform: "iOS", configuration: .init())
  #expect(throws: MisoError.self) {
    try XcodeCompletion.validateDeveloperDisk(data, platform: "watchOS", configuration: .init())
  }
  for (key, value) in [
    ("ProductBuildVersion", "27A9269"), ("Variant", "Internal"), ("BuildVersion", "invalid"),
  ] {
    try data.mergePlist("version.plist", values: [key: value], uid: getuid(), gid: getgid())
    #expect(throws: MisoError.self) {
      try XcodeCompletion.validateDeveloperDisk(data, platform: "iOS", configuration: .init())
    }
    try data.mergePlist("version.plist", values: info, uid: getuid(), gid: getgid())
  }
}

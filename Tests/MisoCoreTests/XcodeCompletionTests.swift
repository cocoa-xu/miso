import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["MISO_XCODE_DDI_ARCHIVE"] != nil))
func nativeDeveloperDisksInstallAndRefreshFromSignedXcode() throws {
  let environment = ProcessInfo.processInfo.environment
  let archive = URL(fileURLWithPath: try #require(environment["MISO_XCODE_DDI_ARCHIVE"]))
  let output = URL(fileURLWithPath: try #require(environment["MISO_XCODE_DDI_OUTPUT"]))
  try #require(geteuid() == 0)
  try SafeFile.makeDirectory(output)
  let receipt = try JSON.read(
    XcodeArchive.Receipt.self, from: archive.appendingPathComponent("archive.json"))
  let packages = output.appendingPathComponent("packages")
  let prepared = try XcodePackages.prepare(preparedArchive: archive, output: packages)
  let policy = try #require(XcodePackages.Policy.standard(receipt.configuration).last)
  let package = try #require(prepared.packages.last)
  let journal = try ExecutionJournal(
    output: output.appendingPathComponent("install"), operation: "ddi-replay")
  _ = try journal.perform {
    let root = journal.output.appendingPathComponent("data")
    try SafeFile.makeDirectory(root)
    let data = try GuestVolume(root)
    let payload = try GuestVolume(
      packages.appendingPathComponent(policy.filename + ".expanded/Payload"))
    let entries = try JSON.read(
      [String: PackageInventory.Entry].self,
      from: packages.appendingPathComponent(package.inventory.path))
    _ = try XcodePackageInstallation.copy(
      payload: payload, entries: entries, policy: policy, data: data, name: "install-resources",
      journal: journal)
    let app = archive.appendingPathComponent(receipt.payload)
    let disks = try XcodeCompletion.installDeveloperDisks(
      data, application: app, configuration: receipt.configuration, journal: journal)
    #expect(Set(disks.map(\.platform)) == ["iOS", "watchOS", "tvOS", "xrOS"])
    return disks
  }
  let refresh = try ExecutionJournal(
    output: output.appendingPathComponent("refresh"), operation: "ddi-refresh-replay")
  _ = try refresh.perform {
    try XcodeCompletion.installDeveloperDisks(
      GuestVolume(journal.output.appendingPathComponent("data")),
      application: archive.appendingPathComponent(receipt.payload),
      configuration: receipt.configuration, journal: refresh, reuseExisting: true)
  }
}

@Test func xcodeRefreshRequiresCompleteUnbootedSourceAndPreservesExistingLayers() throws {
  let configuration = XcodeConfiguration()
  let stages = XcodeCompletion.requiredStages(configuration).sorted() + ["xcode-finalize"]
  let original: [String: Any] = [
    "base_complete": true, "construction_vm_started": false, "runtime_verified": false,
    "xcode_complete": true, "xcode_stages": stages,
    "xcode_configuration": try JSONSerialization.jsonObject(with: JSON.encode(configuration)),
  ]
  try XcodeCompletion.requireStages(
    JSONSerialization.data(withJSONObject: original), configuration: configuration,
    finalized: true, completed: true)
  var refreshed = original
  try BaseImageStage.advanceManifest(
    &refreshed, operation: "xcode-finalize", layer: .xcode, reapply: true)
  #expect(refreshed["xcode_stages"] as? [String] == stages)
  #expect(refreshed["xcode_complete"] as? Bool == false)
  #expect(
    refreshed["xcode_configuration"] as? NSDictionary == original["xcode_configuration"]
      as? NSDictionary)
  for key in ["base_complete", "construction_vm_started", "runtime_verified", "xcode_complete"] {
    var invalid = original
    invalid[key] = !(original[key] as! Bool)
    #expect(throws: MisoError.self) {
      try XcodeCompletion.requireStages(
        JSONSerialization.data(withJSONObject: invalid), configuration: configuration,
        finalized: true, completed: true)
    }
  }
}

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

@Test func developerDisksUseBundledIdentityAndRejectChangedOrIncompleteMetadata() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let data = try GuestVolume(temporary.url)
  let info: [String: Any] = [
    "Platform": "iOS", "ProductBuildVersion": "27A9266e", "Variant": "Public",
    "BuildVersion": "1536",
  ]
  try data.mergePlist("version.plist", values: info, uid: getuid(), gid: getgid())
  #expect(throws: (any Error).self) {
    try XcodeCompletion.validateDeveloperDisk(data, platform: "iOS")
  }
  try data.mergePlist(
    "Restore/BuildManifest.plist", values: ["ProductVersion": "27.0"], uid: getuid(), gid: getgid())
  try data.mergePlist(
    "Restore/Restore.plist", values: ["ProductBuildVersion": "27A266a"], uid: getuid(),
    gid: getgid())
  let identity = try XcodeCompletion.validateDeveloperDisk(data, platform: "iOS")
  #expect(identity.build == "27A9266e" && identity.version == "1536")
  try XcodeCompletion.validateDeveloperDisk(data, platform: "iOS", expected: identity)
  #expect(throws: MisoError.self) {
    try XcodeCompletion.validateDeveloperDisk(data, platform: "watchOS")
  }
  for (key, value) in [
    ("ProductBuildVersion", ""), ("ProductBuildVersion", "27A9269"),
    ("Variant", "Internal"), ("BuildVersion", "invalid"), ("BuildVersion", "1537"),
  ] {
    try data.mergePlist("version.plist", values: [key: value], uid: getuid(), gid: getgid())
    #expect(throws: MisoError.self) {
      try XcodeCompletion.validateDeveloperDisk(data, platform: "iOS", expected: identity)
    }
    try data.mergePlist("version.plist", values: info, uid: getuid(), gid: getgid())
  }
}

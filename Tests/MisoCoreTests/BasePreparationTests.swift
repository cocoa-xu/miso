import Foundation
import Testing

@testable import MisoCore

private func preparationRequest(
  target: MacOSRelease = RestoreProfile.supported[0].release,
  configuration: BaseConfiguration = .init(), jobs: Int = 4
) -> BaseSoftwarePreparation.Request {
  .init(
    target: target, configuration: configuration, sources: .init(), bundlerVersion: nil, jobs: jobs)
}

@Test func basePreparationRejectsIncompleteConfigurationBeforeDownloading() throws {
  let request = preparationRequest()
  try request.validate()
  #expect(try request.nodeRequest == "node@24")
  for jobs in [0, 9] {
    #expect(throws: MisoError.self) { try preparationRequest(jobs: jobs).validate() }
  }
  var missingRuby = BaseConfiguration()
  missingRuby.formulae.removeAll { $0.name == "ruby-build" }
  var multipleNodes = BaseConfiguration()
  multipleNodes.formulae.append(.init(name: "node"))
  var unknownPackage = BaseConfiguration()
  unknownPackage.thirdParty.append(.init(name: "unknown"))
  var emptyNPM = BaseConfiguration()
  emptyNPM.npm = []
  for configuration in [missingRuby, multipleNodes, unknownPackage, emptyNPM] {
    #expect(throws: MisoError.self) {
      try preparationRequest(configuration: configuration).validate()
    }
  }
}

@Test func preparedCacheBindsTargetConfigurationAndEveryStageReceipt() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let root = temporary.url
  let records = try BaseSoftwarePreparation.receiptPaths.map { path in
    let file = try Artifacts.makeParents(for: path, under: root)
    try SafeFile.writeNew(Data(path.utf8), to: file)
    return try Artifacts.record(file, relativeTo: root)
  }
  let request = preparationRequest()
  let receipt = BaseSoftwarePreparation.Receipt(
    schemaVersion: 1, request: request, coreRevision: String(repeating: "a", count: 40),
    versions: [:], receipts: records, softwareInputsComplete: true, completeBaseInputs: false,
    installationVerified: false, runtimeVerified: false)
  try SafeFile.writeNew(JSON.encode(receipt), to: root.appendingPathComponent("preparation.json"))
  try BaseSoftwarePreparation.verifyCache(root, request: request, cancellation: nil)
  #expect(throws: MisoError.self) {
    try BaseSoftwarePreparation.verifyCache(
      root, request: preparationRequest(target: RestoreProfile.supported[1].release),
      cancellation: nil)
  }
  var different = BaseConfiguration()
  different.rubyVersion = "4.0.7"
  #expect(throws: MisoError.self) {
    try BaseSoftwarePreparation.verifyCache(
      root, request: preparationRequest(configuration: different), cancellation: nil)
  }
  try SafeFile.replace(Data("changed".utf8), at: root.appendingPathComponent("ruby/plan.json"))
  #expect(throws: MisoError.self) {
    try BaseSoftwarePreparation.verifyCache(root, request: request, cancellation: nil)
  }
}

@Test func preparationRejectsAmbiguousInputModesWithoutCreatingOutput() async throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("out")
  for (cache, bottles) in [(nil as URL?, nil as URL?), (temporary.url, temporary.url)] {
    await #expect(throws: MisoError.self) {
      try await BaseSoftwarePreparation.run(
        target: RestoreProfile.supported[0].release, output: output,
        cache: cache, resolvedFormulae: temporary.url, resolvedBottles: bottles)
    }
  }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

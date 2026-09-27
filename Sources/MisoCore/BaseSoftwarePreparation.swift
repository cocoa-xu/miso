import Foundation

public enum BaseSoftwarePreparation {
  struct Request: Codable, Equatable {
    let target: MacOSRelease
    let configuration: BaseConfiguration
    let sources: BaseSourceConfiguration
    let bundlerVersion: String?
    let jobs: Int

    var nodeRequest: String {
      get throws {
        let nodes = configuration.formulae.filter {
          $0.name.range(of: #"\Anode(@[0-9]+)?\z"#, options: .regularExpression) != nil
        }
        guard nodes.count == 1 else {
          throw MisoError.invalid("Base preparation requires one Node formula")
        }
        return nodes[0].name
      }
    }

    func validate() throws {
      _ = try RestoreProfile.select(target)
      try configuration.validate()
      try sources.validate()
      _ = try nodeRequest
      if let bundlerVersion { _ = try StableVersion(bundlerVersion) }
      guard (1...8).contains(jobs), configuration.additionalRubyVersions.count < 8,
        Set(configuration.formulae.map(\.name)).isSuperset(of: ["ruby-build", "rbenv"]),
        !configuration.npm.isEmpty,
        Set(configuration.npm.map(\.name)).isSubset(of: ["yarn", "pnpm"]),
        Set(configuration.thirdParty.map(\.name)) == [
          "actions-runner", "buildkite-agent@3", "otel-cli", "tart-guest-agent",
          "git-credential-manager",
        ]
      else { throw MisoError.invalid("Incomplete or unsupported Base software configuration") }
      for package in configuration.npm + configuration.thirdParty {
        if let version = package.version { _ = try StableVersion(version) }
      }
    }
  }

  public struct Receipt: Codable {
    let schemaVersion: Int
    let request: Request
    let coreRevision: String
    let versions: [String: String]
    let receipts: [ImageBundle.FileRecord]
    let softwareInputsComplete: Bool
    let completeBaseInputs: Bool
    let installationVerified: Bool
    let runtimeVerified: Bool
  }

  static let receiptPaths = [
    "core/resolution.json", "bootstrap/archive.json", "bootstrap/resolution.json",
    "bottles/selection.json", "ruby/plan.json", "ruby/resolution.json",
    "runtimes/runtimes.json", "packages/plan.json", "packages/resolution.json",
    "taps/plan.json", "taps/resolution.json", "runner/resolution.json",
    "gcm/plan.json", "gcm/resolution.json",
  ]

  static func coreRevision(_ receipt: HomebrewResolution.Receipt) throws -> String {
    let commits = Set(receipt.formulae.values.map(\.tapCommit))
    guard commits.count == 1, let commit = commits.first else {
      throw MisoError.invalid(
        "Formula metadata spans multiple core snapshots; resolve a coherent snapshot")
    }
    _ = try GitRemote.objectID(commit)
    return commit
  }

  static func verifyCache(_ cache: URL, request: Request, cancellation: CancellationToken?) throws {
    let volume = try GuestVolume(cache)
    let receipt = try JSON.read(Receipt.self, from: volume.path("preparation.json"))
    guard receipt.schemaVersion == 1, receipt.request == request,
      receipt.softwareInputsComplete, !receipt.completeBaseInputs,
      receipt.receipts.map(\.path) == receiptPaths
    else {
      throw MisoError.invalid("Prepared software cache differs from the requested configuration")
    }
    for record in receipt.receipts {
      _ = try Artifacts.resolve(record, under: cache, cancellation: cancellation)
    }
  }

  public static func run(
    target: MacOSRelease, configuration: BaseConfiguration = .init(),
    sources: BaseSourceConfiguration = .init(), bundlerVersion: String? = nil, jobs: Int = 4,
    output: URL, cache: URL? = nil, resolvedFormulae: URL? = nil, resolvedBottles: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    let request = Request(
      target: target, configuration: configuration, sources: sources,
      bundlerVersion: bundlerVersion, jobs: jobs)
    try request.validate()
    guard (resolvedFormulae == nil) == (resolvedBottles == nil),
      cache == nil || resolvedFormulae == nil
    else {
      throw MisoError.invalid(
        "Provide both resolved formulae and bottles, or a complete offline cache")
    }
    if let cache { try verifyCache(cache, request: request, cancellation: cancellation) }
    if let resolvedFormulae {
      let selected = try HomebrewBottleInputs.resolve(
        resolvedFormulae, names: [], cancellation: cancellation)
      guard selected.receipt.target == target, selected.receipt.requests == configuration.formulae
      else {
        throw MisoError.invalid(
          "Provided formula resolution differs from the requested configuration")
      }
    }
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-base-software", cancellation: cancellation)
    func stage(_ name: String) throws -> URL {
      try journal.cancellation.check()
      try journal.setMetadata("stage", value: name)
      return output.appendingPathComponent(name)
    }
    func cached(_ name: String) -> URL? { cache?.appendingPathComponent(name) }
    func version(_ name: String) -> String? {
      configuration.thirdParty.first(where: { $0.name == name })?.version
    }
    do {
      try journal.setMetadata("request", value: request)
      try journal.setMetadata("cacheOnly", value: cache != nil)
      try journal.setMetadata("providedCoreInputs", value: resolvedFormulae != nil)
      let coreURL = try stage("core")
      let core = try await HomebrewResolution.run(
        requests: configuration.formulae, target: target, output: coreURL,
        metadata: cached("core/metadata") ?? resolvedFormulae?.appendingPathComponent("metadata"),
        cancellation: journal.cancellation)
      let revision = try coreRevision(core)
      guard let node = core.selectedRoots[try request.nodeRequest] else {
        throw MisoError.invalid("Missing resolved Node formula")
      }
      let bootstrapURL = try stage("bootstrap")
      let bootstrap = try await BaseBootstrapResolution.run(
        target: target, version: configuration.homebrewVersion, coreRevision: revision,
        sources: sources, output: bootstrapURL, cache: cached("bootstrap"),
        cancellation: journal.cancellation)
      try HomebrewBottleInputs.verifyFormulaSources(
        Array(core.formulae.values),
        core: GuestVolume(bootstrapURL.appendingPathComponent("resources/homebrew-sources/core")),
        cancellation: journal.cancellation)
      let bottlesURL = try stage("bottles")
      _ = try await HomebrewBottleDownload.run(
        resolution: coreURL, output: bottlesURL, cache: cached("bottles") ?? resolvedBottles,
        cancellation: journal.cancellation)
      let rubyURL = try stage("ruby")
      let ruby = try await BaseRubyResolution.run(
        configuration: configuration, resolution: coreURL, bottles: bottlesURL, output: rubyURL,
        cache: cached("ruby"), jobs: jobs, cancellation: journal.cancellation)
      let runtime = try BaseRuntimeInputs.run(
        resolution: coreURL, bottles: bottlesURL, nodeFormula: node,
        rubyPlan: rubyURL.appendingPathComponent("plan.json"), rubyInputs: rubyURL,
        output: stage("runtimes"), cancellation: journal.cancellation)
      let packages = try await BasePackageResolution.run(
        requests: configuration.npm, bundlerVersion: bundlerVersion, target: target,
        rubyVersion: ruby.plan.defaultVersion, nodeFormula: node, runtimes: runtime.runtimes,
        output: stage("packages"), cache: cached("packages"), cancellation: journal.cancellation)
      let taps = try await BaseTapResolution.run(
        requests: configuration.thirdParty.filter {
          !["actions-runner", "git-credential-manager"].contains($0.name)
        }, target: target, sources: sources, output: stage("taps"), cache: cached("taps"),
        cancellation: journal.cancellation)
      let runner = try await BaseRunnerResolution.run(
        target: target, version: version("actions-runner"), output: stage("runner"),
        cache: cached("runner"), cancellation: journal.cancellation)
      let gcm = try await BaseGCMResolution.run(
        target: target, version: version("git-credential-manager"), output: stage("gcm"),
        cache: cached("gcm"), cancellation: journal.cancellation)
      var versions = core.formulae.mapValues(\.kegVersion).reduce(into: [String: String]()) {
        $0["formula/" + $1.key] = $1.value
      }
      versions["homebrew"] = bootstrap.version
      versions["ruby"] = ruby.plan.defaultVersion
      versions["npm"] = runtime.runtimes.npm
      versions["rubygems"] = runtime.runtimes.rubygems
      versions["bundler"] = packages.plan.bundler.version
      versions["actions-runner"] = runner.version
      versions["git-credential-manager"] = gcm.plan.version
      for package in packages.plan.npm { versions[package.name] = package.version }
      for tap in taps.items { versions[tap.request.name] = tap.formula.version }
      let receipt = Receipt(
        schemaVersion: 1, request: request, coreRevision: revision, versions: versions,
        receipts: try receiptPaths.map {
          try Artifacts.record(output.appendingPathComponent($0), relativeTo: output)
        }, softwareInputsComplete: true, completeBaseInputs: false,
        installationVerified: false, runtimeVerified: false)
      try SafeFile.writeNew(
        JSON.encode(receipt), to: output.appendingPathComponent("preparation.json"))
      try journal.finish(receipt)
      return receipt
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

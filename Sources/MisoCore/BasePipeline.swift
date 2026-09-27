import Darwin
import Foundation

@MainActor
public enum BasePipeline {
  public struct Receipt: Encodable {
    let target: MacOSRelease
    let recipeSHA256: String
    let bundle: String
    let files: [ImageBundle.FileRecord]
    let stages: [String]
    let configuration: VirtualHardware.ValidationReceipt
    let baseComplete: Bool
    let runtimeVerified = false
    let vmStarted = false
  }

  static func verifyInputs(
    _ recipe: BaseBuildRecipe, inputs: URL, cancellation: CancellationToken
  ) throws {
    try recipe.validate()
    _ = try preflight(recipe, inputs: GuestVolume(inputs), cancellation: cancellation)
  }

  public static func run(
    source: URL, recipe recipeURL: URL, inputs: URL, output: URL,
    keepIntermediates: Bool = false, cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Base construction requires administrator privileges")
    }
    let recipeHash = try SafeFile.sha256(recipeURL)
    let recipe = try JSON.read(BaseBuildRecipe.self, from: recipeURL)
    try recipe.validate()
    let inputVolume = try GuestVolume(inputs)
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
      throw MisoError.invalid("Cannot locate native build executable")
    }
    let executableHash = try SafeFile.sha256(executable)
    let sourceVolume = try GuestVolume(source)
    let sourceManifest = try Artifacts.record(
      sourceVolume.path("manifest.json"), relativeTo: source)
    try requireVanilla(
      SafeFile.read(sourceVolume.path("manifest.json"), limit: 1 << 20), target: recipe.target)
    let journal = try ExecutionJournal(
      output: output, operation: "base-build", cancellation: cancellation)
    return try journal.perform {
      try journal.setMetadata("recipe", value: recipe)
      try journal.setMetadata("stage", value: "preflight")
      let plans = try preflight(recipe, inputs: inputVolume, cancellation: journal.cancellation)
      _ = try VirtualHardware.validateBundle(source)
      var current = source
      var previous: URL?
      var completed: [String] = []
      var certificateDetails: BaseCertificates.Details?
      for (index, step) in recipe.steps.enumerated() {
        try journal.cancellation.check()
        for record in step.files.values {
          _ = try Artifacts.resolve(record, under: inputs, cancellation: journal.cancellation)
        }
        guard try SafeFile.sha256(executable) == executableHash else {
          throw MisoError.invalid("Native build executable changed")
        }
        let name = String(format: "%02d-%@", index + 1, step.stage.rawValue)
        try journal.setMetadata("stage", value: name)
        let stage = output.appendingPathComponent(name)
        let arguments =
          try recipe.arguments(
            for: step, inputs: inputVolume, nodeFormula: plans.packages.nodeFormula)
          + ["--source", current.path, "--output", stage.path]
        let log = try journal.run(
          step.stage.operation,
          NativeCommand(executable.path, arguments: arguments, timeout: step.stage.timeout))
        try validateStage(stage, operation: step.stage.operation, target: recipe.target)
        for record in step.files.values {
          _ = try Artifacts.resolve(record, under: inputs, cancellation: journal.cancellation)
        }
        if step.stage == .certificates {
          struct Result: Decodable { let details: BaseCertificates.Details }
          certificateDetails = try JSON.read(Result.self, from: log).details
        }
        current = stage.appendingPathComponent("bundle")
        _ = try VirtualHardware.validateBundle(current)
        if !keepIntermediates {
          try BaseStageWorkspace.prune(stage, image: false, journal: journal)
          if let previous { try BaseStageWorkspace.prune(previous, image: true, journal: journal) }
        }
        previous = stage
        completed.append(step.stage.operation)
        try journal.setMetadata("completedStages", value: completed)
      }
      guard let certificates = certificateDetails else {
        throw MisoError.invalid("Missing certificate receipt")
      }
      let cleanupPlan = BaseCleanup.Plan(
        schemaVersion: 1, target: recipe.target, nodeFormula: plans.packages.nodeFormula,
        pythonFormula: plans.ca.pythonFormula, pythonExecutable: plans.ca.pythonExecutable,
        rubyVersions: plans.ruby.builds.map(\.version), certificateBundle: certificates.bundle,
        certificateCount: certificates.certificateFingerprints.count)
      try cleanupPlan.validate()
      let cleanupPlanURL = output.appendingPathComponent("cleanup-plan.json")
      try SafeFile.writeNew(JSON.encode(cleanupPlan), to: cleanupPlanURL)
      let finalStage = output.appendingPathComponent("11-cleanup")
      try journal.setMetadata("stage", value: "11-cleanup")
      try journal.run(
        "base-cleanup",
        NativeCommand(
          executable.path,
          arguments: [
            "base", "cleanup", "--source", current.path, "--plan", cleanupPlanURL.path,
            "--output", finalStage.path, "--username", recipe.username,
          ], timeout: 1800))
      try validateStage(finalStage, operation: "base-cleanup", target: recipe.target)
      current = finalStage.appendingPathComponent("bundle")
      completed.append("base-cleanup")
      let configuration = try VirtualHardware.validateBundle(current)
      _ = try ImageBundle.verify(source)
      guard
        try Artifacts.record(sourceVolume.path("manifest.json"), relativeTo: source)
          == sourceManifest,
        try SafeFile.sha256(recipeURL) == recipeHash,
        try SafeFile.sha256(executable) == executableHash
      else { throw MisoError.invalid("Base build inputs changed") }
      if !keepIntermediates {
        try BaseStageWorkspace.prune(finalStage, image: false, journal: journal)
        if let previous { try BaseStageWorkspace.prune(previous, image: true, journal: journal) }
      }
      let manifestURL = try GuestVolume(current).path("manifest.json")
      guard
        var manifest = try JSONSerialization.jsonObject(
          with: SafeFile.read(manifestURL, limit: 1 << 20)) as? [String: Any],
        manifest["base_stages"] as? [String] == completed
      else { throw MisoError.invalid("Final Base stage lineage differs") }
      manifest["base_complete"] = true
      try SafeFile.replace(
        JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
        at: manifestURL)
      let verified = try ImageBundle.verify(current)
      try journal.setMetadata("completedStages", value: completed)
      return Receipt(
        target: recipe.target, recipeSHA256: recipeHash, bundle: "11-cleanup/bundle",
        files: verified.files, stages: completed, configuration: configuration, baseComplete: true)
    }
  }

  static func requireVanilla(_ data: Data, target: MacOSRelease) throws {
    guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      manifest["construction_vm_started"] as? Bool == false,
      manifest["runtime_verified"] as? Bool == false,
      manifest["base_complete"] as? Bool != true,
      manifest["base_stages"] == nil || manifest["base_stages"] as? [String] == [],
      manifest["target"] as? [String: String] == ["version": target.version, "build": target.build]
    else { throw MisoError.invalid("A fresh never-booted Vanilla source is required") }
  }

  private static func validateStage(_ stage: URL, operation: String, target: MacOSRelease) throws {
    let record = try JSON.read(
      ExecutionJournal.Record.self, from: stage.appendingPathComponent("journal.json"))
    guard record.status == .complete, record.operation == operation, !record.vmStarted,
      let result = record.result,
      let fields = try JSONSerialization.jsonObject(with: JSON.encode(result)) as? [String: Any],
      fields["originalsUnchanged"] as? Bool == true,
      fields["baseComplete"] as? Bool == false,
      fields["runtimeVerified"] as? Bool == false,
      fields["target"] as? [String: String] == ["version": target.version, "build": target.build]
    else { throw MisoError.invalid("Base stage receipt is incomplete") }
    _ = try ImageBundle.verify(stage.appendingPathComponent("bundle"))
  }

  private struct Plans {
    let ruby: BaseRuby.Plan
    let packages: BasePackageInputs.Plan
    let ca: BaseCAInputs.Plan
  }

  private static func preflight(
    _ recipe: BaseBuildRecipe, inputs: GuestVolume, cancellation: CancellationToken
  ) throws -> Plans {
    var releases: [MacOSRelease] = []
    var ruby: BaseRuby.Plan?
    var packages: BasePackageInputs.Plan?
    var ca: BaseCAInputs.Plan?
    var core: GuestVolume?
    var formulae: [HomebrewResolution.Formula] = []
    var agents: [String] = []
    var configuredAgents: [String] = []
    for step in recipe.steps {
      for (key, record) in step.files {
        do {
          _ = try Artifacts.resolve(record, under: inputs.root, cancellation: cancellation)
        } catch {
          throw MisoError.invalid("Base \(step.stage.rawValue) input \(key): \(error)")
        }
      }
      func file(_ key: String) throws -> URL { try inputs.path(step.files[key]!.path) }
      func directory(_ key: String) throws -> URL {
        do {
          return try inputs.directory(step.directories[key]!).url
        } catch {
          throw MisoError.invalid("Base \(step.stage.rawValue) directory \(key): \(error)")
        }
      }
      for key in step.directories.keys { _ = try directory(key) }
      switch step.stage {
      case .static: break
      case .bootstrap:
        let archive = try file("archive").deletingLastPathComponent()
        _ = try BaseInputArchive.verify(archive, cancellation: cancellation)
        core = try GuestVolume(
          GuestVolume(archive).directory("resources/homebrew-sources/core").url)
      case .bottles:
        let bottles = try HomebrewBottleInputs.load(
          resolution: file("resolution").deletingLastPathComponent(),
          bottles: directory("bottles"), names: step.formulae!, cancellation: cancellation)
        guard let core else { throw MisoError.invalid("Missing bootstrap core snapshot") }
        try HomebrewBottleInputs.verifyFormulaSources(
          bottles.payloads.map(\.formula), core: core, cancellation: cancellation)
        formulae = bottles.payloads.map(\.formula)
        releases.append(bottles.target)
      case .ruby:
        ruby = try BaseRuby.verify(
          plan: file("plan"), inputs: directory("inputs"), cancellation: cancellation)
        releases.append(ruby!.target)
      case .packages:
        packages = try BasePackageInputs.verify(
          plan: file("plan"), inputs: directory("inputs"), cancellation: cancellation)
        releases.append(packages!.target)
      case .taps:
        let taps = try BaseTapInputs.verify(
          plan: file("plan"), inputs: directory("inputs"), cancellation: cancellation)
        agents = taps.taps.flatMap(\.formulas).filter { $0.name == "tart-guest-agent" }.map(
          \.kegVersion)
        releases.append(taps.target)
      case .gcm:
        releases.append(
          try BaseGCMInputs.verify(
            plan: file("plan"), inputs: directory("inputs"), cancellation: cancellation
          ).target)
      case .security:
        let plan = try JSON.read(BaseSecurity.Plan.self, from: file("plan"))
        try plan.validate()
        configuredAgents.append(plan.tartVersion)
        releases.append(plan.target)
      case .settings:
        let plan = try JSON.read(BaseSystemSettings.Plan.self, from: file("plan"))
        try plan.validate()
        configuredAgents.append(plan.tartVersion)
        releases.append(plan.target)
      case .certificates:
        ca = try BaseCAInputs.verify(
          plan: file("plan"), inputs: directory("inputs"), cancellation: cancellation)
        releases.append(ca!.target)
      }
    }
    guard releases.allSatisfy({ $0 == recipe.target }), let ruby, let packages, let ca,
      ruby.builds.contains(where: { $0.version == packages.rubyVersion })
    else { throw MisoError.invalid("Base recipe target or Ruby identities differ") }
    try verifyBindings(
      formulae: formulae.map(\.name), node: packages.nodeFormula, python: ca.pythonFormula,
      agents: agents, configuredAgents: configuredAgents)
    return Plans(ruby: ruby, packages: packages, ca: ca)
  }

  static func verifyBindings(
    formulae: [String], node: String, python: String, agents: [String], configuredAgents: [String]
  ) throws {
    guard formulae.contains(node), formulae.contains(python), agents.count == 1,
      configuredAgents.count == 2, configuredAgents.allSatisfy({ $0 == agents[0] })
    else { throw MisoError.invalid("Base recipe runtime or guest-agent versions differ") }
  }
}

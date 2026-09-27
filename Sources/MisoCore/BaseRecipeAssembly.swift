import Foundation

@MainActor
public enum BaseRecipeAssembly {
  public struct Receipt: Encodable {
    let target: MacOSRelease
    let preparationSHA256: String
    let templateSHA256: String
    let recipe: ImageBundle.FileRecord
    let inputPreflightVerified: Bool
    let bootMaterialVerified = false
    let installationVerified = false
    let runtimeVerified = false
    let vmStarted = false
  }

  static func bind(
    template: BaseBuildRecipe, preparation: BaseSoftwarePreparation.Receipt,
    runner: BaseRunnerResolution.Receipt, formulae: [String], prefix: String
  ) throws -> BaseBuildRecipe {
    try template.validate()
    guard template.target == preparation.request.target, runner.target == template.target else {
      throw MisoError.invalid("Recipe template and prepared software targets differ")
    }
    func path(_ relative: String) throws -> String {
      try SafeFile.relativePath(prefix.isEmpty ? relative : prefix + "/" + relative)
    }
    func record(_ original: ImageBundle.FileRecord) throws -> ImageBundle.FileRecord {
      .init(path: try path(original.path), bytes: original.bytes, sha256: original.sha256)
    }
    func prepared(_ name: String) throws -> ImageBundle.FileRecord {
      guard let file = preparation.receipts.first(where: { $0.path == name }) else {
        throw MisoError.invalid("Missing prepared software receipt: \(name)")
      }
      return try record(file)
    }
    func runnerFile(_ file: ImageBundle.FileRecord) throws -> ImageBundle.FileRecord {
      try record(.init(path: "runner/" + file.path, bytes: file.bytes, sha256: file.sha256))
    }
    let steps = try template.steps.map { step -> BaseBuildRecipe.Step in
      switch step.stage {
      case .static:
        return .init(
          stage: .static,
          files: [
            "runner": try runnerFile(runner.runner),
            "runner-release": try runnerFile(runner.release),
            "known-hosts": step.files["known-hosts"]!,
          ], directories: [:], formulae: nil)
      case .bootstrap:
        return .init(
          stage: .bootstrap, files: ["archive": try prepared("bootstrap/archive.json")],
          directories: [:], formulae: nil)
      case .bottles:
        return .init(
          stage: .bottles, files: ["resolution": try prepared("core/resolution.json")],
          directories: ["bottles": try path("bottles")],
          formulae: formulae)
      case .ruby, .packages, .taps, .gcm:
        return .init(
          stage: step.stage, files: ["plan": try prepared(step.stage.rawValue + "/plan.json")],
          directories: ["inputs": try path(step.stage.rawValue)], formulae: nil)
      case .security, .settings, .certificates: return step
      }
    }
    let recipe = BaseBuildRecipe(
      schemaVersion: 1, target: template.target, username: template.username, steps: steps)
    try recipe.validate()
    return recipe
  }

  public static func run(
    software: URL, template templateURL: URL, inputs: URL, output: URL,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    let volume = try GuestVolume(inputs)
    let softwareRoot = try GuestVolume(software)
    let preparationURL = try softwareRoot.path("preparation.json")
    let source = try Artifacts.record(preparationURL, relativeTo: volume.root)
    let preparation = try JSON.read(BaseSoftwarePreparation.Receipt.self, from: preparationURL)
    try preparation.request.validate()
    try BaseSoftwarePreparation.verifyCache(
      software, request: preparation.request, cancellation: cancellation)
    let templateHash = try SafeFile.sha256(templateURL)
    let template = try JSON.read(BaseBuildRecipe.self, from: templateURL)
    let runner = try JSON.read(
      BaseRunnerResolution.Receipt.self, from: softwareRoot.path("runner/resolution.json"))
    let core = try JSON.read(
      HomebrewResolution.Receipt.self, from: softwareRoot.path("core/resolution.json"))
    guard core.target == preparation.request.target,
      core.requests == preparation.request.configuration.formulae
    else { throw MisoError.invalid("Prepared core resolution differs from software configuration") }
    let recipe = try bind(
      template: template, preparation: preparation, runner: runner,
      formulae: Array(Set(core.selectedRoots.values)).sorted(),
      prefix: (source.path as NSString).deletingLastPathComponent)
    let journal = try ExecutionJournal(
      output: output, operation: "assemble-base-recipe", cancellation: cancellation)
    return try journal.perform {
      try journal.setMetadata("target", value: recipe.target)
      try BasePipeline.verifyInputs(recipe, inputs: inputs, cancellation: journal.cancellation)
      guard try SafeFile.sha256(templateURL) == templateHash,
        try Artifacts.record(preparationURL, relativeTo: volume.root) == source
      else { throw MisoError.invalid("Recipe assembly inputs changed") }
      let destination = output.appendingPathComponent("recipe.json")
      try SafeFile.writeNew(JSON.encode(recipe), to: destination)
      return Receipt(
        target: recipe.target, preparationSHA256: source.sha256, templateSHA256: templateHash,
        recipe: try Artifacts.record(destination, relativeTo: output), inputPreflightVerified: true)
    }
  }
}

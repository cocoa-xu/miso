import ArgumentParser
import Foundation
import MisoCore

struct Base: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare target-compatible Base inputs without starting a VM.",
    subcommands: [
      Defaults.self, Resolve.self, Archive.self, Static.self, Bootstrap.self, Bottles.self,
    ])

  struct Bottles: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate or install resolved local Homebrew bottles.",
      subcommands: [Verify.self, Install.self])

    struct Inputs: ParsableArguments {
      @Option var resolution: String
      @Option var bottles: String
      @Option var formula: [String] = []
    }

    struct Verify: ParsableCommand {
      @OptionGroup var inputs: Inputs
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          HomebrewBottleInputs.load(
            resolution: fileURL(inputs.resolution), bottles: fileURL(inputs.bottles),
            names: inputs.formula, cancellation: cancellation.token))
      }
    }

    struct Install: ParsableCommand {
      @OptionGroup var inputs: Inputs
      @Option var source: String
      @Option var output: String
      @Option var username = "admin"
      @Flag(help: "Run upstream post-install methods and target software probes.") var postInstall =
        false
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseBottles.run(
            source: fileURL(source),
            resolution: fileURL(inputs.resolution), bottles: fileURL(inputs.bottles),
            names: inputs.formula, output: fileURL(output), username: username,
            postInstall: postInstall,
            cancellation: cancellation.token))
      }
    }
  }

  struct Bootstrap: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Install archived Homebrew inputs and verify restricted target execution on a clone.")
    @Option var source: String
    @Option var archive: String
    @Option var output: String
    @Option var username = "admin"
    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BaseBootstrap.run(
          source: fileURL(source), archive: fileURL(archive), output: fileURL(output),
          username: username, cancellation: cancellation.token))
    }
  }

  struct Static: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Apply and audit the static Base layer on a cloned Vanilla bundle.")
    @Option var source: String
    @Option var runner: String
    @Option var runnerRelease: String
    @Option var knownHosts: String
    @Option var output: String
    @Option var username = "admin"
    @Option var nodeFormula = "node@24"
    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BaseStaticLayer.run(
          source: fileURL(source), runner: fileURL(runner),
          release: fileURL(runnerRelease), knownHosts: fileURL(knownHosts), output: fileURL(output),
          username: username, nodeFormula: nodeFormula, cancellation: cancellation.token))
    }
  }

  struct Defaults: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the default Base configuration; omitted versions resolve dynamically.")
    func run() throws { try printJSON(BaseConfiguration()) }
  }

  struct Resolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Resolve core formula metadata and sources; does not install packages.")
    @Option var targetVersion: String
    @Option var targetBuild: String
    @Option var config: String?
    @Option var formula: [String] = []
    @Option var metadata: String?
    @Option var output: String

    func run() async throws {
      guard config == nil || formula.isEmpty else {
        throw ValidationError("Use --config or --formula, not both")
      }
      let settings =
        try config.map { try JSON.read(BaseConfiguration.self, from: fileURL($0)) }
        ?? BaseConfiguration()
      try settings.validate()
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await HomebrewResolution.run(
          requests: formula.isEmpty ? settings.formulae : formula.map { PackageRequest(name: $0) },
          target: MacOSRelease(version: targetVersion, build: targetBuild), output: fileURL(output),
          metadata: metadata.map(fileURL), cancellation: cancellation.token))
    }
  }

  struct Archive: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Preserve and verify portable, self-contained input snapshots.",
      subcommands: [Create.self, Verify.self])

    struct Create: ParsableCommand {
      @Option var spec: String
      @Option var output: String
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseInputArchive.create(
            specification: fileURL(spec), output: fileURL(output), cancellation: cancellation.token)
        )
      }
    }

    struct Verify: ParsableCommand {
      @Argument var directory: String
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(BaseInputArchive.verify(fileURL(directory), cancellation: cancellation.token))
      }
    }
  }
}

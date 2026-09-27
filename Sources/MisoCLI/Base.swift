import ArgumentParser
import Foundation
import MisoCore

struct Base: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare target-compatible Base inputs without starting a VM.",
    subcommands: [
      Defaults.self, Resolve.self, Archive.self, Static.self, Bootstrap.self, Bottles.self,
      Ruby.self, Packages.self, Taps.self, GCM.self, Security.self, Settings.self, CA.self,
      Cleanup.self, Build.self,
    ])

  struct Build: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Build an offline Base bundle from verified replay inputs.")
    @Option var source: String
    @Option var recipe: String
    @Option var inputs: String
    @Option var output: String
    @Flag var keepIntermediates = false
    @MainActor func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BasePipeline.run(
          source: fileURL(source), recipe: fileURL(recipe), inputs: fileURL(inputs),
          output: fileURL(output), keepIntermediates: keepIntermediates,
          cancellation: cancellation.token))
    }
  }

  struct Cleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove build caches and audit offline Base functionality.")
    @Option var source: String
    @Option var plan: String
    @Option var output: String
    @Option var username = "admin"
    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BaseCleanup.run(
          source: fileURL(source), plan: fileURL(plan), output: fileURL(output),
          username: username, cancellation: cancellation.token))
    }
  }

  struct CA: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "ca", abstract: "Verify or install target-derived certificate bundles.",
      subcommands: [Verify.self, Install.self])
    struct Inputs: ParsableArguments {
      @Option var plan: String
      @Option var inputs: String
    }
    struct Verify: ParsableCommand {
      @OptionGroup var inputs: Inputs
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseCAInputs.verify(
            plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            cancellation: cancellation.token))
      }
    }
    struct Install: ParsableCommand {
      @OptionGroup var inputs: Inputs
      @Option var source: String
      @Option var output: String
      @Option var username = "admin"
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseCertificates.run(
            source: fileURL(source), plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            output: fileURL(output), username: username, cancellation: cancellation.token))
      }
    }
  }

  struct Settings: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Install offline guest-agent and Spotlight settings.")
    @Option var source: String
    @Option var plan: String
    @Option var output: String
    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BaseSystemSettings.run(
          source: fileURL(source), plan: fileURL(plan),
          output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct Security: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Apply explicit offline Base security and automation settings.")
    @Option var source: String
    @Option var plan: String
    @Option var boot: String
    @Option var material: String
    @Option var output: String
    @Option var username = "admin"
    @MainActor func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BaseSecurity.run(
          source: fileURL(source), plan: fileURL(plan), boot: fileURL(boot),
          material: fileURL(material), output: fileURL(output), username: username,
          cancellation: cancellation.token))
    }
  }

  struct GCM: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "gcm",
      abstract: "Install a verified credential manager package and offline Git configuration.",
      subcommands: [Verify.self, Inspect.self, Install.self])

    struct Inputs: ParsableArguments {
      @Option var plan: String
      @Option var inputs: String
    }

    struct Verify: ParsableCommand {
      @OptionGroup var inputs: Inputs
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseGCMInputs.verify(
            plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            cancellation: cancellation.token))
      }
    }

    struct Inspect: ParsableCommand {
      @OptionGroup var inputs: Inputs
      @Option var output: String
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseGCMInputs.inspect(
            plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            output: fileURL(output), cancellation: cancellation.token))
      }
    }

    struct Install: ParsableCommand {
      @OptionGroup var inputs: Inputs
      @Option var source: String
      @Option var output: String
      @Option var username = "admin"
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseGCM.run(
            source: fileURL(source), plan: fileURL(inputs.plan),
            inputs: fileURL(inputs.inputs), output: fileURL(output), username: username,
            cancellation: cancellation.token))
      }
    }
  }

  struct Taps: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate or install resolved local Homebrew tap inputs.",
      subcommands: [Verify.self, Install.self])

    struct Inputs: ParsableArguments {
      @Option var plan: String
      @Option var inputs: String
    }

    struct Verify: ParsableCommand {
      @OptionGroup var inputs: Inputs
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseTapInputs.verify(
            plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            cancellation: cancellation.token))
      }
    }

    struct Install: ParsableCommand {
      @OptionGroup var inputs: Inputs
      @Option var source: String
      @Option var output: String
      @Option var username = "admin"
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseTaps.run(
            source: fileURL(source), plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            output: fileURL(output), username: username, cancellation: cancellation.token))
      }
    }
  }

  struct Packages: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate or install resolved local Bundler and npm packages.",
      subcommands: [Resolve.self, Verify.self, Install.self])

    struct Resolve: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Resolve and download target-compatible Bundler, yarn and pnpm inputs.")
      @Option var targetVersion: String
      @Option var targetBuild: String
      @Option var rubyVersion: String
      @Option var rubygemsVersion: String
      @Option var nodeFormula: String
      @Option var nodeVersion: String
      @Option var npmVersion: String
      @Option var bundlerVersion: String?
      @Option var config: String?
      @Option var cache: String?
      @Option var output: String

      func run() async throws {
        let settings =
          try config.map { try JSON.read(BaseConfiguration.self, from: fileURL($0)) }
          ?? BaseConfiguration()
        try settings.validate()
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          await BasePackageResolution.run(
            requests: settings.npm, bundlerVersion: bundlerVersion,
            target: MacOSRelease(version: targetVersion, build: targetBuild),
            rubyVersion: rubyVersion,
            nodeFormula: nodeFormula,
            runtimes: .init(node: nodeVersion, npm: npmVersion, rubygems: rubygemsVersion),
            output: fileURL(output), cache: cache.map(fileURL), cancellation: cancellation.token))
      }
    }

    struct Inputs: ParsableArguments {
      @Option var plan: String
      @Option var inputs: String
    }

    struct Verify: ParsableCommand {
      @OptionGroup var inputs: Inputs
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BasePackageInputs.verify(
            plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            cancellation: cancellation.token))
      }
    }

    struct Install: ParsableCommand {
      @OptionGroup var inputs: Inputs
      @Option var source: String
      @Option var output: String
      @Option var username = "admin"
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BasePackages.run(
            source: fileURL(source), plan: fileURL(inputs.plan),
            inputs: fileURL(inputs.inputs), output: fileURL(output), username: username,
            cancellation: cancellation.token))
      }
    }
  }

  struct Ruby: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Build resolved Ruby sources using the target toolchain without booting.",
      subcommands: [Resolve.self, Verify.self, Install.self])

    struct Resolve: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Resolve Ruby sources from a target-compatible ruby-build bottle.")
      @Option var config: String?
      @Option var resolution: String
      @Option var bottles: String
      @Option var cache: String?
      @Option var output: String
      @Option var jobs = 4

      func run() async throws {
        let settings =
          try config.map { try JSON.read(BaseConfiguration.self, from: fileURL($0)) }
          ?? BaseConfiguration()
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          await BaseRubyResolution.run(
            configuration: settings, resolution: fileURL(resolution), bottles: fileURL(bottles),
            output: fileURL(output), cache: cache.map(fileURL), jobs: jobs,
            cancellation: cancellation.token))
      }
    }

    struct Inputs: ParsableArguments {
      @Option var plan: String
      @Option var inputs: String
    }

    struct Verify: ParsableCommand {
      @OptionGroup var inputs: Inputs
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseRuby.verify(
            plan: fileURL(inputs.plan), inputs: fileURL(inputs.inputs),
            cancellation: cancellation.token))
      }
    }

    struct Install: ParsableCommand {
      @OptionGroup var inputs: Inputs
      @Option var source: String
      @Option var output: String
      @Option var username = "admin"
      func run() throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          BaseRuby.run(
            source: fileURL(source), plan: fileURL(inputs.plan),
            inputs: fileURL(inputs.inputs), output: fileURL(output), username: username,
            cancellation: cancellation.token))
      }
    }
  }

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

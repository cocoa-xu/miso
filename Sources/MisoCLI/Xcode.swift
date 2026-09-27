import ArgumentParser
import Foundation
import MisoCore

struct Xcode: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare exact-version Xcode inputs without starting a VM.",
    subcommands: [
      Defaults.self, PrepareArchive.self, PrepareMetal.self, PreparePackages.self,
      PrepareRuntime.self,
      InstallApplication.self, InstallPackages.self, InstallBottles.self, InstallRuntime.self,
      InstallMetal.self, PrepareGems.self, InstallGems.self, PrepareCasks.self, InstallCasks.self,
      PrepareSimulatorTools.self, InstallSimulatorTools.self,
      PrepareTuist.self, InstallTuist.self, PrepareAndroid.self,
    ])

  struct PrepareAndroid: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-android",
      abstract: "Prepare the configured Android SDK and NDK packages without installing them.")
    @Option var targetVersion: String
    @Option var targetBuild: String
    @Option var cache: String?
    @Option var output: String

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeAndroidInputs.prepare(
          target: .init(version: targetVersion, build: targetBuild), output: fileURL(output),
          cache: cache.map(fileURL), cancellation: cancellation.token))
    }
  }

  struct InstallTuist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-tuist",
      abstract: "Register and pin the prepared Tuist CLI with mise in an offline clone.")
    @Option var source: String
    @Option var prepared: String
    @Option var output: String
    @Option var username = "admin"

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeTuistInstallation.install(
          source: fileURL(source), prepared: fileURL(prepared), output: fileURL(output),
          username: username, cancellation: cancellation.token))
    }
  }

  struct PrepareTuist: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-tuist",
      abstract: "Resolve and verify the stable Tuist CLI from its pinned official tap.")
    @Option var targetVersion: String
    @Option var targetBuild: String
    @Option var cache: String?
    @Option var output: String

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeTuistInputs.prepare(
          target: .init(version: targetVersion, build: targetBuild), output: fileURL(output),
          cache: cache.map(fileURL), cancellation: cancellation.token))
    }
  }

  struct PrepareSimulatorTools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-simulator-tools",
      abstract: "Prepare the pinned Wix simulator utilities bottle and tap.")
    @Option var targetVersion: String
    @Option var targetBuild: String
    @Option var cache: String?
    @Option var output: String

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeSimulatorTools.prepare(
          target: .init(version: targetVersion, build: targetBuild), output: fileURL(output),
          cache: cache.map(fileURL), cancellation: cancellation.token))
    }
  }

  struct InstallSimulatorTools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-simulator-tools",
      abstract: "Install the prepared Wix bottle into an offline image clone.")
    @Option var source: String
    @Option var prepared: String
    @Option var output: String
    @Option var username = "admin"

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeSimulatorTools.install(
          source: fileURL(source), prepared: fileURL(prepared), output: fileURL(output),
          username: username, cancellation: cancellation.token))
    }
  }

  struct InstallCasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-casks",
      abstract: "Install prepared developer casks into an offline image clone.")
    @Option var source: String
    @Option var prepared: String
    @Option var output: String
    @Option var username = "admin"

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeCaskInstallation.install(
          source: fileURL(source), prepared: fileURL(prepared), output: fileURL(output),
          username: username, cancellation: cancellation.token))
    }
  }

  struct PrepareCasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-casks",
      abstract: "Verify and expand the standard developer casks without installing them.")
    @Option var targetVersion: String
    @Option var targetBuild: String
    @Option var cache: String?
    @Option var output: String

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeCaskInputs.prepare(
          target: .init(version: targetVersion, build: targetBuild), output: fileURL(output),
          cache: cache.map(fileURL), cancellation: cancellation.token))
    }
  }

  struct PrepareGems: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-gems",
      abstract: "Resolve and checksum the mobile Ruby tool dependency graph.")
    @Option var rubyVersion: String
    @Option var rubygemsVersion: String
    @Option var bundlerVersion: String
    @Option var cache: String?
    @Option var output: String

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeGemInputs.prepare(
          rubyVersion: rubyVersion, rubygemsVersion: rubygemsVersion,
          bundlerVersion: bundlerVersion,
          output: fileURL(output), cache: cache.map(fileURL), cancellation: cancellation.token))
    }
  }

  struct InstallGems: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-gems",
      abstract: "Install prepared mobile Ruby tools without network or VM startup.")
    @Option var source: String
    @Option var prepared: String
    @Option var output: String
    @Option var username = "admin"

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        XcodeGemInstallation.install(
          source: fileURL(source), prepared: fileURL(prepared), output: fileURL(output),
          username: username, cancellation: cancellation.token))
    }
  }

  struct InstallPackages: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-packages",
      abstract: "Install reviewed Xcode package payloads and receipts offline.")
    @Option var source: String
    @Option var prepared: String
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        XcodePackageInstallation.install(
          source: fileURL(source), preparedArchive: fileURL(prepared),
          output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct InstallRuntime: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-runtime",
      abstract: "Authenticate and install one simulator runtime into an offline image clone.")
    @Option var source: String
    @Option var prepared: String
    @Option var config: String?
    @Option var output: String

    func run() async throws {
      let settings =
        try config.map { try JSON.read(XcodeConfiguration.self, from: fileURL($0)) }
        ?? XcodeConfiguration()
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeRuntimeInstallation.install(
          source: fileURL(source), prepared: fileURL(prepared), configuration: settings,
          output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct InstallMetal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-metal",
      abstract: "Install an authenticated Metal toolchain without modifying the Xcode application.")
    @Option var source: String
    @Option var prepared: String
    @Option var config: String?
    @Option var username = "admin"
    @Option var output: String

    func run() async throws {
      let settings =
        try config.map { try JSON.read(XcodeConfiguration.self, from: fileURL($0)) }
        ?? XcodeConfiguration()
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeMetalInstallation.install(
          source: fileURL(source), prepared: fileURL(prepared), configuration: settings,
          username: username, output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct InstallBottles: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-bottles",
      abstract: "Install developer bottles bound to the image's exact Xcode configuration.")
    @Option var source: String
    @Option var resolution: String
    @Option var bottles: String
    @Option var formula: [String] = []
    @Option var username = "admin"
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BaseBottles.installXcode(
          source: fileURL(source), resolution: fileURL(resolution), bottles: fileURL(bottles),
          names: formula,
          output: fileURL(output), username: username, cancellation: cancellation.token))
    }
  }

  struct PrepareRuntime: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-runtime",
      abstract: "Authenticate an arm64 simulator asset without installing it on the host.")
    @Option var platform: String
    @Option var runtimeVersion: String
    @Option var runtimeBuild: String
    @Option var config: String?
    @Option var catalog: String?
    @Option var archive: String?
    @Option var output: String

    func run() async throws {
      guard let platform = XcodeConfiguration.Platform(rawValue: platform) else {
        throw ValidationError("Expected iOS, watchOS, tvOS or visionOS")
      }
      let settings =
        try config.map { try JSON.read(XcodeConfiguration.self, from: fileURL($0)) }
        ?? XcodeConfiguration()
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await XcodeRuntime.prepare(
          requirement: .init(platform: platform, version: runtimeVersion, build: runtimeBuild),
          configuration: settings,
          catalog: catalog.map(fileURL), archive: archive.map(fileURL), output: fileURL(output),
          cancellation: cancellation.token))
    }
  }

  struct PreparePackages: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-packages",
      abstract: "Verify first-launch packages without running their scripts.")
    @Option var prepared: String
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        XcodePackages.prepare(
          preparedArchive: fileURL(prepared), output: fileURL(output),
          cancellation: cancellation.token))
    }
  }

  struct InstallApplication: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "install-application",
      abstract: "Install verified Xcode into a never-booted Base clone.")
    @Option var source: String
    @Option var prepared: String
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        XcodeApplication.install(
          source: fileURL(source), prepared: fileURL(prepared), output: fileURL(output),
          cancellation: cancellation.token))
    }
  }

  struct PrepareMetal: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-metal",
      abstract: "Download and verify the exact Xcode Metal asset without installing it on the host."
    )
    @Option var config: String?
    @Option(help: "Signed catalog for offline replay; requires --archive.") var catalog: String?
    @Option(help: "Encrypted Apple asset for offline replay; requires --catalog.") var archive:
      String?
    @Option var output: String

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      let settings =
        try config.map { try JSON.read(XcodeConfiguration.self, from: fileURL($0)) }
        ?? XcodeConfiguration()
      try printJSON(
        await XcodeMetal.prepare(
          configuration: settings, catalog: catalog.map(fileURL), archive: archive.map(fileURL),
          output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct Defaults: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the standard Xcode configuration.")
    func run() throws { try printJSON(XcodeConfiguration()) }
  }

  struct PrepareArchive: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "prepare-archive", abstract: "Verify and expand an Apple-signed Xcode XIP.")
    @Option var archive: String
    @Option var sha256: String
    @Option var targetVersion: String
    @Option var targetBuild: String
    @Option var config: String?
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      let settings =
        try config.map { try JSON.read(XcodeConfiguration.self, from: fileURL($0)) }
        ?? XcodeConfiguration()
      try printJSON(
        XcodeArchive.prepare(
          archive: fileURL(archive), sha256: sha256,
          target: .init(version: targetVersion, build: targetBuild), configuration: settings,
          output: fileURL(output), cancellation: cancellation.token))
    }
  }
}

import ArgumentParser
import Foundation
import MisoCore

struct Xcode: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare exact-version Xcode inputs without starting a VM.",
    subcommands: [Defaults.self, PrepareArchive.self, PrepareMetal.self, InstallApplication.self])

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

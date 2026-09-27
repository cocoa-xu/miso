import ArgumentParser
import Foundation
import MisoCore

struct Xcode: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare exact-version Xcode inputs without starting a VM.",
    subcommands: [Defaults.self, PrepareArchive.self])

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

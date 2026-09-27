import ArgumentParser
import Foundation
import MisoCore

extension Base {
  struct Runner: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Resolve and preserve Actions Runner inputs without starting a VM.",
      subcommands: [Resolve.self])

    struct Resolve: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract:
          "Resolve a stable arm64 runner release and inspect its executable deployment targets.")
      @Option var targetVersion: String
      @Option var targetBuild: String
      @Option var packageVersion: String?
      @Option var output: String
      @Option var cache: String?

      func run() async throws {
        let cancellation = try CancellationScope()
        defer { withExtendedLifetime(cancellation) {} }
        try printJSON(
          await BaseRunnerResolution.run(
            target: .init(version: targetVersion, build: targetBuild), version: packageVersion,
            output: fileURL(output), cache: cache.map(fileURL), cancellation: cancellation.token))
      }
    }
  }
}

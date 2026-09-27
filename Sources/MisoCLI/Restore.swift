import ArgumentParser
import Foundation
import MisoCore

struct Restore: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Build a vanilla image through native offline stages; administrator privileges required.")
  @Argument var ipsw: String
  @Option var config: String?
  @Option var packages: String
  @Option var output: String
  @Option var diskBytes: UInt64 = 40 << 30

  @MainActor func run() async throws {
    let cancellation = try CancellationScope()
    defer { withExtendedLifetime(cancellation) {} }
    let settings =
      try config.map { try ImageConfiguration.read(fileURL($0)) } ?? ImageConfiguration()
    try printJSON(
      await RestorePipeline.run(
        ipsw: fileURL(ipsw), configuration: settings,
        packages: fileURL(packages), output: fileURL(output), diskBytes: diskBytes,
        cancellation: cancellation.token))
  }
}

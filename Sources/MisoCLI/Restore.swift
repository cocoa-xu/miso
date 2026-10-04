import ArgumentParser
import Foundation
import MisoCore

struct Restore: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Build a vanilla image through native offline stages; administrator privileges required.")
  @Argument(help: "Local IPSW path or Apple HTTPS restore URL.") var ipsw: String
  @Option var config: String?
  @Option var packages: String
  @Option var output: String
  @Option var diskBytes: UInt64 = 40 << 30
  @Flag(help: "Keep the downloaded IPSW after preparation. Local IPSWs are always preserved.")
  var keepDownloads = false

  @MainActor func run() async throws {
    let cancellation = try CancellationScope()
    defer { withExtendedLifetime(cancellation) {} }
    let settings =
      try config.map { try ImageConfiguration.read(fileURL($0)) } ?? ImageConfiguration()
    let source: URL
    if ipsw.contains("://") {
      guard let url = URL(string: ipsw), url.scheme == "https" else {
        throw ValidationError("Use a local IPSW path or an Apple HTTPS restore URL")
      }
      source = url
    } else {
      source = fileURL(ipsw)
    }
    try printJSON(
      await RestorePipeline.run(
        ipsw: source, configuration: settings,
        packages: fileURL(packages), output: fileURL(output), diskBytes: diskBytes,
        keepDownloads: keepDownloads,
        cancellation: cancellation.token))
  }
}

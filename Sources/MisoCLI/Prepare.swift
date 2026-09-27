import ArgumentParser
import Foundation
import MisoCore

struct Prepare: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Prepare authenticated restore inputs and native decoding artifacts without creating a VM.")
  @Argument var ipsw: String
  @Option var config: String?
  @Option(help: "New directory on a volume with sufficient free space.") var output: String

  mutating func run() async throws {
    let cancellation = try CancellationScope()
    defer { withExtendedLifetime(cancellation) {} }
    let configuration =
      try config.map { try ImageConfiguration.read(fileURL($0)) } ?? ImageConfiguration()
    let result = try await RestorePreparation.run(
      ipsw: fileURL(ipsw), configuration: configuration, output: fileURL(output),
      cancellation: cancellation.token)
    try printJSON(result)
  }
}

import ArgumentParser
import Foundation
import MisoCore

struct Personalize: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Prepare native boot personalization inputs.",
    subcommands: [Material.self, Boot.self])

  struct Boot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Personalize boot payloads without creating or starting a VM.")
    @Option var prepared: String
    @Option var toolsStage: String
    @Option var materialStage: String
    @Option var output: String

    @MainActor func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        await BootPersonalization.run(
          prepared: fileURL(prepared), toolsStage: fileURL(toolsStage),
          materialStage: fileURL(materialStage), output: fileURL(output),
          cancellation: cancellation.token))
    }
  }

  struct Material: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Extract policy material directly from a verified kernelcache.")
    @Option var prepared: String
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        KernelCollection.prepare(
          prepared: fileURL(prepared), output: fileURL(output), cancellation: cancellation.token))
    }
  }
}

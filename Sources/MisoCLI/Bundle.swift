import ArgumentParser
import Foundation
import MisoCore

struct Bundle: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check bundle integrity or validate a VM configuration without creating a VM.",
    subcommands: [Verify.self, Validate.self, Assemble.self, Optimize.self, ExportTart.self])

  struct Optimize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Compress installed payloads and reclaim APFS free blocks in a new offline clone.")
    @Argument var directory: String
    @Option var output: String
    @Option var username = "admin"
    @Flag(
      inversion: .prefixedNo,
      help: "Compress eligible installed files before reclaiming free blocks.")
    var compress = true

    func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        ImageOptimization.run(
          source: fileURL(directory), output: fileURL(output),
          username: username, compress: compress, cancellation: cancellation.token))
    }
  }

  struct ExportTart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Export a verified offline bundle for Tart OCI publication without starting a VM.")
    @Argument var directory: String
    @Option var output: String

    @MainActor func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        TartBundle.export(
          source: fileURL(directory), output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct Assemble: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Install personalized boot payloads and audit a new image bundle offline.")
    @Option var prepared: String
    @Option var toolsStage: String
    @Option var bootStage: String
    @Option var output: String

    @MainActor func run() async throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        BundleAssembly.run(
          prepared: fileURL(prepared), toolsStage: fileURL(toolsStage),
          bootStage: fileURL(bootStage), output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Hash every required bundle file and compare with manifest.json.")
    @Argument var directory: String
    func run() throws { try printJSON(ImageBundle.verify(fileURL(directory))) }
  }

  struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Validate read-only Virtualization.framework configuration; does not prove bootability.")
    @Argument var directory: String
    @Option var cpus = 4
    @Option var memoryBytes: UInt64 = 4 << 30
    func run() async throws {
      let report = try await VirtualHardware.validateBundle(
        fileURL(directory), cpuCount: cpus, memoryBytes: memoryBytes)
      try printJSON(report)
    }
  }
}

struct Identity: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract:
      "Create a hardware identity and empty auxiliary storage from a digest-verified IPSW; does not install macOS."
  )
  @Argument var ipsw: String
  @Option var output: String

  func run() async throws {
    try printJSON(
      await VirtualHardware.createIdentity(ipsw: fileURL(ipsw), output: fileURL(output)))
  }
}

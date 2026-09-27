import ArgumentParser
import Foundation
import MisoCore

struct Disk: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect image ownership and create partitioned raw System seeds.",
    subcommands: [Layout.self, Seed.self, Inspect.self])

  struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Attach a GPT image read-only without mounting its volumes, inspect owned APFS containers, then detach."
    )
    @Argument var image: String
    @Option(help: "New directory for the operation journal.") var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      let journal = try ExecutionJournal(
        output: fileURL(output), operation: "inspect-disk", cancellation: cancellation.token)
      let result = try journal.perform {
        let session = try DiskImageSession(image: fileURL(image), readOnly: true, journal: journal)
        return try session.withAttachment { try $0.containers() }
      }
      try printJSON(result)
    }
  }

  struct Layout: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Calculate a GPT layout without creating a disk.")
    @Option var diskBytes: UInt64
    @Option var sourceBytes: UInt64
    func run() throws { try printJSON(DiskLayout(diskBytes: diskBytes, sourceBytes: sourceBytes)) }
  }

  struct Seed: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Copy a raw System APFS container into a new GPT disk; this is not a finished bootable image."
    )
    @Option var source: String
    @Option var output: String
    @Option var diskBytes: UInt64
    @Option var sha256: String
    func run() throws {
      try printJSON(
        DiskLayout.create(
          source: fileURL(source), output: fileURL(output), diskBytes: diskBytes,
          expectedSHA256: sha256))
    }
  }
}

struct Decode: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Decode bounded component payloads.", subcommands: [DecodePBZE.self, DecodeAEA.self])

  struct DecodePBZE: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "pbze", abstract: "Stream PBZE chunks into a new output file.")
    @Argument var source: String
    @Option var output: String
    func run() throws {
      try printJSON(PBZE.decode(source: fileURL(source), output: fileURL(output)))
    }
  }
}

import ArgumentParser
import Foundation
import MisoCore

struct Disk: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect image ownership and create partitioned raw System seeds.",
    subcommands: [
      Layout.self, Seed.self, Inspect.self, Seal.self, Volumes.self, Populate.self, Tools.self,
    ])

  struct Tools: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Install pinned Command Line Tools on a populated image clone.")
    @Option var prepared: String
    @Option var dataStage: String
    @Option var packages: String
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        ToolsConstruction.run(
          prepared: fileURL(prepared), dataStage: fileURL(dataStage),
          packages: fileURL(packages), output: fileURL(output), cancellation: cancellation.token))
    }
  }

  struct Populate: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Copy the Data template and configure an offline account on a volume-stage clone.")
    @Option var prepared: String
    @Option var volumeStage: String
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        DataConstruction.run(
          prepared: fileURL(prepared), volumeStage: fileURL(volumeStage), output: fileURL(output),
          cancellation: cancellation.token))
    }
  }

  struct Volumes: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Create support volumes on a clone of a sealed System disk; administrator privileges required."
    )
    @Option var prepared: String
    @Option var systemStage: String
    @Option var output: String

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        VolumeConstruction.run(
          prepared: fileURL(prepared), systemStage: fileURL(systemStage), output: fileURL(output),
          cancellation: cancellation.token))
    }
  }

  struct Seal: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Create and verify a sealed System disk from completed preparation; administrator privileges required."
    )
    @Option var prepared: String
    @Option var output: String
    @Option var diskBytes: UInt64 = 40 << 30

    func run() throws {
      let cancellation = try CancellationScope()
      defer { withExtendedLifetime(cancellation) {} }
      try printJSON(
        SystemConstruction.run(
          prepared: fileURL(prepared), output: fileURL(output), diskBytes: diskBytes,
          cancellation: cancellation.token))
    }
  }

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

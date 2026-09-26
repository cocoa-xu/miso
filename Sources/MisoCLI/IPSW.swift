import ArgumentParser
import Foundation
import MisoCore

struct IPSW: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ipsw",
    abstract: "Inspect and extract restore archives without mounting an image.",
    subcommands: [Inspect.self, Extract.self])

  struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate restore metadata and component membership.")
    @Argument var archive: String
    @Flag(help: "Hash the complete archive and require the profile's exact SHA-256.")
    var verifyDigest = false

    func run() throws {
      try printJSON(RestoreInspection.inspect(fileURL(archive), verifyDigest: verifyDigest))
    }
  }

  struct Extract: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Extract one regular member to a new file and require its SHA-256.")
    @Argument var archive: String
    @Option var member: String
    @Option var output: String
    @Option var sha256: String

    func run() throws {
      try printJSON(
        IPSWArchive(fileURL(archive)).extract(member, to: fileURL(output), expectedSHA256: sha256))
    }
  }
}

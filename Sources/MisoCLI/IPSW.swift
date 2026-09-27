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
      abstract: "Extract one regular member using a pinned member or complete archive SHA-256.")
    @Argument var archive: String
    @Option var member: String
    @Option var output: String
    @Option(help: "Expected member SHA-256.") var sha256: String?
    @Option(help: "Expected complete IPSW SHA-256; required when the member digest is omitted.")
    var archiveSha256: String?

    func run() throws {
      try printJSON(
        IPSWArchive(fileURL(archive), expectedSHA256: archiveSha256).extract(
          member, to: fileURL(output), expectedSHA256: sha256))
    }
  }
}

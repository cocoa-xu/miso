import ArgumentParser
import Foundation
import MisoCore

@main
struct Miso: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "miso",
    abstract: "Offline macOS image tools.",
    version: "0.1.0-dev",
    subcommands: [Profiles.self, Configuration.self]
  )
}

func printJSON(_ value: some Encodable) throws {
  try FileHandle.standardOutput.write(contentsOf: JSON.encode(value))
}

func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }

struct Profiles: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List recognized restore and upgrade targets.")

  func run() throws {
    struct Report: Encodable {
      let restore = RestoreProfile.supported
      let upgrade = UpgradeProfile.supported
    }
    try printJSON(Report())
  }
}

struct Configuration: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config", abstract: "Create and check image configuration.",
    subcommands: [Defaults.self, Check.self])

  struct Defaults: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the default admin/admin configuration.")
    func run() throws { try printJSON(ImageConfiguration()) }
  }

  struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate a configuration without printing credentials.")
    @Argument(help: "Configuration JSON file.") var path: String

    func run() throws {
      _ = try ImageConfiguration.read(fileURL(path))
      try printJSON(["configurationValid": true, "vmStarted": false])
    }
  }
}

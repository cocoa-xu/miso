import ArgumentParser
import Foundation
import MisoCore

@main
struct Miso: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "miso",
    abstract: "Offline macOS image tools.",
    version: "0.3.1",
    subcommands: [
      Profiles.self, Configuration.self, IPSW.self, Disk.self, Decode.self, Identity.self,
      Bundle.self, Upgrade.self, Prepare.self, Personalize.self, Restore.self, Base.self,
      Xcode.self, GuestExecute.self, SecurityProbe.self,
    ]
  )
}

func printJSON(_ value: some Encodable) throws {
  try FileHandle.standardOutput.write(contentsOf: JSON.encode(value))
}

func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path).standardized }

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

struct Upgrade: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Plan offline same-major upgrades.", subcommands: [Plan.self])

  struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Produce a conflict-free three-way Data template plan; no image is modified.")
    @Option var sourceVersion: String
    @Option var sourceBuild: String
    @Option var targetVersion: String
    @Option var targetBuild: String
    @Option var oldTemplate: String
    @Option var newTemplate: String
    @Option var dataInventory: String

    func run() throws {
      let profile = try UpgradeProfile.select(
        source: .init(version: sourceVersion, build: sourceBuild),
        target: .init(version: targetVersion, build: targetBuild))
      let inventories = try [oldTemplate, newTemplate, dataInventory].map {
        try JSON.read(TemplateUpgrade.Inventory.self, from: fileURL($0))
      }
      let actions = try TemplateUpgrade.plan(
        old: inventories[0], new: inventories[1], current: inventories[2])
      try TemplateUpgrade.requireUnambiguous(actions)
      struct Report: Encodable {
        let schemaVersion = 1
        let profile: UpgradeProfile
        let actions: [TemplateUpgrade.Action]
        let imageModified = false
        let vmStarted = false
      }
      try printJSON(Report(profile: profile, actions: actions))
    }
  }
}

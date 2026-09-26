import ArgumentParser
import Foundation
import MisoCore

@main
struct Miso: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "miso",
    abstract: "Offline macOS image tools.",
    version: "0.1.0-dev",
    subcommands: []
  )
}

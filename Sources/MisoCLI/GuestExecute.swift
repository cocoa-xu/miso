import ArgumentParser
import Foundation
import MisoSystem

struct SecurityProbe: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_security-probe", shouldDisplay: false)
  func run() throws {
    let result = miso_security_probe()
    guard result == 0 else { throw ExitCode(result) }
  }
}

struct GuestExecute: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "_guest-exec", shouldDisplay: false)
  @Option var root: String
  @Option var uid: UInt32
  @Option var gid: UInt32
  @Option var username: String
  @Option var capability: String
  @Argument(parsing: .unconditionalRemaining) var arguments: [String] = []

  func run() throws {
    guard !arguments.isEmpty, arguments.allSatisfy({ !$0.contains("\0") }),
      [root, username, capability].allSatisfy({ !$0.contains("\0") })
    else { throw ValidationError("Invalid guest execution arguments") }
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in pointers { free(pointer) } }
    for argument in arguments {
      guard let pointer = strdup(argument) else {
        throw ValidationError("Argument allocation failed")
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    pointers.withUnsafeBufferPointer {
      miso_guest_exec(root, uid, gid, username, capability, $0.baseAddress!)
    }
  }
}

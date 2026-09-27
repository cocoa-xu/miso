import ArgumentParser
import Foundation
import MisoCore

struct DecodeAEA: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "aea",
    abstract: "Decrypt an AEA component in process into a new operation directory.")
  @Argument var source: String
  @Option(help: "New directory for the payload and operation journal.") var output: String
  @Option(
    help: "Local recipient PEM; otherwise retrieve it from the component's Apple HTTPS endpoint.")
  var privateKey: String?
  @Option(help: "Maximum decrypted size in bytes.") var maximumBytes: UInt64 = 128 << 30

  mutating func run() async throws {
    let cancellation = try CancellationScope()
    defer { withExtendedLifetime(cancellation) {} }
    let journal = try ExecutionJournal(
      output: fileURL(output), operation: "decode-aea", cancellation: cancellation.token)
    do {
      let input = fileURL(source)
      let key = try await AEA.decryptionKey(
        input, privateKeyPEM: privateKey.map(fileURL), cancellation: cancellation.token)
      let result = try journal.perform {
        try EncryptedArchive.decrypt(
          source: input, output: journal.output.appendingPathComponent("payload.bin"), key: key,
          maximumOutputBytes: maximumBytes, cancellation: cancellation.token)
      }
      try printJSON(result)
    } catch {
      if journal.record.status == .running { try journal.fail(error) }
      throw error
    }
  }
}

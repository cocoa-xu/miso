import Foundation

enum GitReferences {
  struct Receipt: Codable {
    let schemaVersion: Int
    let repository: String
    let prefix: String
    let capabilities: ImageBundle.FileRecord
    let references: ImageBundle.FileRecord
  }

  static func run(
    repository: String, prefix: String, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> GitRemote {
    let origin = try GitRemote.repositoryURL(repository)
    let request = try GitRemote.referenceRequest(prefix)
    try SafeFile.makeDirectory(output)
    let capabilities = output.appendingPathComponent("capabilities.bin")
    let references = output.appendingPathComponent("references.bin")
    if let cache {
      let cached = try GuestVolume(cache)
      let receipt = try JSON.read(Receipt.self, from: cached.path("references.json"))
      guard receipt.schemaVersion == 1, receipt.repository == repository, receipt.prefix == prefix,
        receipt.capabilities.path == "capabilities.bin", receipt.references.path == "references.bin"
      else { throw MisoError.invalid("Git reference cache differs from request") }
      for (record, path, limit) in [
        (receipt.capabilities, capabilities, 65_536), (receipt.references, references, 8 << 20),
      ] {
        guard record.bytes <= limit else {
          throw MisoError.invalid("Oversized Git reference cache")
        }
        try Artifacts.copy(
          Artifacts.resolve(record, under: cache, cancellation: cancellation),
          to: path, maximumBytes: UInt64(limit), cancellation: cancellation)
      }
    } else {
      try await SafeFile.writeNew(
        HTTPData.get(
          URL(string: origin.absoluteString + "/info/refs?service=git-upload-pack")!,
          maximumBytes: 65_536, cancellation: cancellation, gitProtocolV2: true), to: capabilities)
      try GitRemote.validateCapabilities(SafeFile.read(capabilities, limit: 65_536))
      try await HTTPFile.post(
        origin.appendingPathComponent("git-upload-pack"), body: request,
        contentType: "application/x-git-upload-pack-request", to: references, maximumBytes: 8 << 20,
        cancellation: cancellation, gitProtocolV2: true)
    }
    let remote = try GitRemote(
      capabilities: SafeFile.read(capabilities, limit: 65_536),
      references: SafeFile.read(references, limit: 8 << 20))
    let receipt = try Receipt(
      schemaVersion: 1, repository: repository, prefix: prefix,
      capabilities: Artifacts.record(capabilities, relativeTo: output),
      references: Artifacts.record(references, relativeTo: output))
    try SafeFile.writeNew(
      JSON.encode(receipt), to: output.appendingPathComponent("references.json"))
    return remote
  }
}

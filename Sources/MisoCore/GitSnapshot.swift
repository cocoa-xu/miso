import Foundation

enum GitSnapshot {
  struct Receipt: Codable, Equatable {
    let schemaVersion: Int
    let repository: String
    let selection: GitRemote.Selection
    let capabilities: ImageBundle.FileRecord
    let advertisement: ImageBundle.FileRecord
    let response: ImageBundle.FileRecord
  }

  static func run(
    repository: String, reference: String? = nil, expectedCommit: String? = nil,
    pinned: GitRemote.Selection? = nil,
    output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Receipt {
    let origin = try GitRemote.repositoryURL(repository)
    if let expectedCommit { _ = try GitRemote.objectID(expectedCommit) }
    if let pinned {
      guard pinned.reference == (reference ?? "HEAD") else {
        throw MisoError.invalid("Pinned Git reference differs from request")
      }
      _ = try GitRemote.fetchRequest(pinned)
    }
    let cached = try cache.map { try GuestVolume($0) }
    let previous = try cached.map { try JSON.read(Receipt.self, from: $0.path("snapshot.json")) }
    if let previous {
      guard previous.schemaVersion == 1, previous.repository == repository,
        previous.selection.reference == (reference ?? "HEAD"),
        previous.capabilities.path == "capabilities.bin", previous.capabilities.bytes <= 65_536,
        previous.advertisement.path == "advertisement.bin", previous.advertisement.bytes <= 8 << 20,
        previous.response.path == "response.bin", previous.response.bytes <= (128 << 20) + 65_536
      else { throw MisoError.invalid("Git cache differs from requested snapshot") }
    }
    try cancellation?.check()
    try SafeFile.makeDirectory(output)
    let capabilities: Data
    if let previous, let cache {
      capabilities = try SafeFile.read(
        Artifacts.resolve(previous.capabilities, under: cache, cancellation: cancellation),
        limit: 65_536)
    } else {
      capabilities = try await HTTPData.get(
        URL(string: origin.absoluteString + "/info/refs?service=git-upload-pack")!,
        maximumBytes: 65_536, cancellation: cancellation, gitProtocolV2: true,
        configuration: configuration)
    }
    try GitRemote.validateCapabilities(capabilities)
    try SafeFile.writeNew(capabilities, to: output.appendingPathComponent("capabilities.bin"))
    let advertisement: Data
    if let previous, let cache {
      advertisement = try SafeFile.read(
        Artifacts.resolve(previous.advertisement, under: cache, cancellation: cancellation),
        limit: 8 << 20)
    } else {
      let path = output.appendingPathComponent("advertisement.bin")
      try await HTTPFile.post(
        origin.appendingPathComponent("git-upload-pack"),
        body: GitRemote.referenceRequest(pinned == nil ? (reference ?? "HEAD") : "HEAD"),
        contentType: "application/x-git-upload-pack-request", to: path, maximumBytes: 8 << 20,
        cancellation: cancellation, gitProtocolV2: true, configuration: configuration)
      advertisement = try SafeFile.read(path, limit: 8 << 20)
    }
    let remote = try GitRemote(capabilities: capabilities, references: advertisement)
    let selection = try pinned ?? remote.select(reference)
    if let expectedCommit, expectedCommit != selection.commitID {
      throw MisoError.invalid("Git reference differs from required upstream commit")
    }
    if cached != nil {
      try SafeFile.writeNew(advertisement, to: output.appendingPathComponent("advertisement.bin"))
    }
    let response = output.appendingPathComponent("response.bin")
    if let previous, let cache {
      guard previous.selection == selection else {
        throw MisoError.invalid("Cached Git selection changed")
      }
      try Artifacts.copy(
        Artifacts.resolve(previous.response, under: cache, cancellation: cancellation),
        to: response, maximumBytes: previous.response.bytes, cancellation: cancellation)
    } else {
      try await HTTPFile.post(
        origin.appendingPathComponent("git-upload-pack"), body: GitRemote.fetchRequest(selection),
        contentType: "application/x-git-upload-pack-request", to: response,
        maximumBytes: (128 << 20) + 65_536, cancellation: cancellation,
        gitProtocolV2: true, configuration: configuration
      )
    }
    let pack = try GitPack(
      GitRemote.response(
        SafeFile.read(response, limit: (128 << 20) + 65_536), selection: selection),
      cancellation: cancellation)
    let checkout = try GitCheckout(pack: pack, selection: selection, cancellation: cancellation)
    try checkout.write(
      to: output.appendingPathComponent("checkout"), pack: pack, origin: origin,
      cancellation: cancellation)
    let receipt = Receipt(
      schemaVersion: 1, repository: repository, selection: selection,
      capabilities: try Artifacts.record(
        output.appendingPathComponent("capabilities.bin"), relativeTo: output),
      advertisement: try Artifacts.record(
        output.appendingPathComponent("advertisement.bin"), relativeTo: output),
      response: try Artifacts.record(response, relativeTo: output))
    if let previous, receipt != previous {
      throw MisoError.invalid("Replayed Git snapshot differs from cache")
    }
    try SafeFile.writeNew(JSON.encode(receipt), to: output.appendingPathComponent("snapshot.json"))
    return receipt
  }
}

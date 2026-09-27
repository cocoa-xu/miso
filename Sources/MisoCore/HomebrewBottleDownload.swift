import Foundation

public enum HomebrewBottleDownload {
  public static func run(
    resolution: URL, names: [String] = [], output: URL, cache: URL? = nil, reuse: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> HomebrewBottleInputs.Selection {
    guard cache == nil || reuse == nil else {
      throw MisoError.invalid("Use either offline cache replay or partial download reuse")
    }
    let resolved = try HomebrewBottleInputs.resolve(
      resolution, names: names, cancellation: cancellation)
    let cached = try cache.map { try GuestVolume($0) }
    let reusable = try reuse.map { try GuestVolume($0) }
    if let reusable {
      let previous = try JSON.read(
        ExecutionJournal.Record.self, from: reusable.path("journal.json"))
      guard previous.operation == "download-homebrew-bottles",
        previous.metadata["resolutionSHA256"] == .string(resolved.sha256),
        previous.status != .running
      else { throw MisoError.invalid("Cannot reuse an active or different bottle resolution") }
    }
    let journal = try ExecutionJournal(
      output: output, operation: "download-homebrew-bottles", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: resolved.receipt.target)
      try journal.setMetadata("resolutionSHA256", value: resolved.sha256)
      try journal.setMetadata("cacheOnly", value: cache != nil)
      for formula in resolved.formulae {
        try journal.cancellation.check()
        try journal.setMetadata("downloading", value: formula.name)
        let indexName = formula.name + ".tar.index.json"
        let archiveName = formula.name + ".tar.gz"
        let archive = output.appendingPathComponent(archiveName)
        let index: Data
        let available: GuestVolume?
        if let cached {
          available = cached
        } else if let reusable,
          try reusable.contains(indexName), try reusable.contains(archiveName)
        {
          available = reusable
        } else {
          available = nil
        }
        if let available {
          index = try SafeFile.read(available.path(indexName), limit: 8 << 20)
          try Artifacts.copy(
            available.path(archiveName), to: archive, maximumBytes: 512 << 20,
            cancellation: journal.cancellation)
        } else {
          index = try await HTTPData.homebrewIndex(
            HomebrewRegistry.index(formula), cancellation: journal.cancellation)
          try await HTTPFile.homebrewBlob(
            formula.bottle.url, to: archive, maximumBytes: 512 << 20,
            cancellation: journal.cancellation)
        }
        let record = try Artifacts.record(archive, relativeTo: output)
        guard record.sha256 == formula.bottle.sha256, record.bytes > 0 else {
          throw MisoError.invalid("Bottle checksum mismatch: \(formula.name)")
        }
        _ = try HomebrewBottleInputs.parseIndex(index, formula: formula, bytes: record.bytes)
        try SafeFile.writeNew(index, to: output.appendingPathComponent(indexName))
        try journal.setMetadata("downloaded", value: formula.name)
      }
      let selection = try HomebrewBottleInputs.load(
        resolution: resolution, bottles: output, names: names, cancellation: journal.cancellation)
      guard selection.resolutionSHA256 == resolved.sha256 else {
        throw MisoError.invalid("Resolution changed during download")
      }
      try SafeFile.writeNew(
        JSON.encode(selection), to: output.appendingPathComponent("selection.json"))
      try journal.finish(selection)
      return selection
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

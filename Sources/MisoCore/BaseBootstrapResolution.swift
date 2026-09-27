import Foundation

public enum BaseBootstrapResolution {
  struct Ruby: Codable {
    let version: String
    let sha256: String
    let bytes: UInt64
  }

  public struct Receipt: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let requestedVersion: String?
    let requestedCoreRevision: String?
    let sources: BaseSourceConfiguration
    let version: String
    let brew: GitSnapshot.Receipt
    let core: GitSnapshot.Receipt
    let compatibility: [ImageBundle.FileRecord]
    let rubyProbes: [HomebrewRubyProbe]?
    let portableRuby: ImageBundle.FileRecord
    let portableRubyMinimumMacOS: String
    let archiveSHA256: String
    let installationVerified: Bool
  }

  static func assignment(_ key: String, in bytes: Data) throws -> String {
    guard bytes.count <= 256 << 10, let text = String(data: bytes, encoding: .utf8) else {
      throw MisoError.invalid("Invalid Homebrew source metadata")
    }
    let matches = text.split(separator: "\n").filter { $0.hasPrefix(key + "=") }
    guard matches.count == 1 else {
      throw MisoError.unsupported("Missing or ambiguous Homebrew \(key)")
    }
    var value = String(matches[0].dropFirst(key.count + 1))
    if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
    guard !value.isEmpty,
      value.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [46, 95, 45].contains($0)
      })
    else {
      throw MisoError.unsupported("Nonliteral Homebrew \(key)")
    }
    return value
  }

  static func minimumMacOS(_ bytes: Data) throws -> MacOSVersion {
    let value = try assignment("HOMEBREW_MACOS_OLDEST_ALLOWED", in: bytes)
    return try MacOSVersion(value.contains(".") ? value : value + ".0")
  }

  static func candidates(_ remote: GitRemote, requested: String?) throws -> [(
    String, GitRemote.Selection
  )] {
    if let requested {
      _ = try StableVersion(requested)
      return [(requested, try remote.select("refs/tags/" + requested))]
    }
    let versions = remote.references.values.compactMap {
      selected -> (String, GitRemote.Selection, StableVersion)? in
      guard selected.reference.hasPrefix("refs/tags/") else { return nil }
      let version = String(selected.reference.dropFirst(10))
      guard version.split(separator: ".").count == 3, let stable = try? StableVersion(version)
      else { return nil }
      return (version, selected, stable)
    }.sorted { $0.2 > $1.2 }
    guard !versions.isEmpty else { throw MisoError.invalid("No stable Homebrew tags advertised") }
    return versions.map { ($0.0, $0.1) }
  }

  public static func run(
    target: MacOSRelease, version: String? = nil, coreRevision: String? = nil,
    sources: BaseSourceConfiguration = .init(),
    output: URL, cache: URL? = nil, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    try sources.validate()
    if let version { _ = try StableVersion(version) }
    if let coreRevision { _ = try GitRemote.objectID(coreRevision) }
    let previous = try cache.map {
      try JSON.read(Receipt.self, from: GuestVolume($0).path("resolution.json"))
    }
    if let previous {
      guard previous.schemaVersion == 1, previous.target == target,
        previous.requestedVersion == version,
        previous.requestedCoreRevision == coreRevision,
        previous.sources == sources, previous.compatibility.count <= 256,
        (previous.rubyProbes?.count ?? 0) <= 256
      else { throw MisoError.invalid("Homebrew bootstrap cache differs from request") }
    }
    let journal = try ExecutionJournal(
      output: output, operation: "resolve-base-bootstrap", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: target)
      let remote = try await GitReferences.run(
        repository: "Homebrew/brew", prefix: version.map { "refs/tags/" + $0 } ?? "refs/tags/",
        output: output.appendingPathComponent("catalog"),
        cache: cache?.appendingPathComponent("catalog"), cancellation: journal.cancellation)
      let candidates = try candidates(remote, requested: version)
      let compatibilityRoot = output.appendingPathComponent("compatibility")
      try SafeFile.makeDirectory(compatibilityRoot)
      try SafeFile.makeDirectory(output.appendingPathComponent("ruby-candidates"))
      var scripts: [ImageBundle.FileRecord] = []
      var rubyProbes: [HomebrewRubyProbe] = []
      var selected: (String, GitRemote.Selection, HomebrewRubyProbe)?
      for candidate in candidates.prefix(256) {
        try journal.cancellation.check()
        let path = "compatibility/\(candidate.0).sh"
        let destination = output.appendingPathComponent(path)
        let bytes: Data
        if let previous, let cache {
          let matches = previous.compatibility.filter { $0.path == path }
          guard matches.count == 1 else {
            throw MisoError.invalid("Missing cached Homebrew compatibility probe")
          }
          bytes = try SafeFile.read(
            Artifacts.resolve(matches[0], under: cache, cancellation: journal.cancellation),
            limit: 256 << 10)
        } else {
          bytes = try await HTTPData.get(
            URL(
              string:
                "https://raw.githubusercontent.com/Homebrew/brew/\(candidate.1.commitID)/Library/Homebrew/brew.sh"
            )!,
            maximumBytes: 256 << 10, cancellation: journal.cancellation)
        }
        try SafeFile.writeNew(bytes, to: destination)
        scripts.append(try Artifacts.record(destination, relativeTo: output))
        if try minimumMacOS(bytes) <= MacOSVersion(target.version) {
          let cached = previous?.rubyProbes?.filter { $0.version == candidate.0 } ?? []
          guard cached.count <= 1 else { throw MisoError.invalid("Duplicate portable Ruby probe") }
          let ruby = try await HomebrewRubyProbe.run(
            version: candidate.0, commit: candidate.1.commitID, output: output, cache: cache,
            previous: cached.first,
            legacyPayload: previous?.rubyProbes == nil && previous?.version == candidate.0
              ? previous?.portableRuby : nil,
            cancellation: journal.cancellation)
          rubyProbes.append(ruby)
          if try MacOSVersion(ruby.minimumMacOS) <= MacOSVersion(target.version) {
            selected = (candidate.0, candidate.1, ruby)
            break
          }
        }
      }
      guard let selected else {
        throw MisoError.unsupported(
          "No compatible Homebrew found; specify a version or replay preserved inputs")
      }
      let brew = try await GitSnapshot.run(
        repository: sources.repository("Homebrew/brew"), reference: selected.1.reference,
        expectedCommit: selected.1.commitID, pinned: selected.1,
        output: output.appendingPathComponent("brew"),
        cache: cache?.appendingPathComponent("brew"), cancellation: journal.cancellation)
      let coreSelection: GitRemote.Selection
      if let coreRevision {
        coreSelection = .init(reference: "HEAD", objectID: coreRevision, commitID: coreRevision)
      } else {
        let coreRefs = try await GitReferences.run(
          repository: "Homebrew/homebrew-core", prefix: "HEAD",
          output: output.appendingPathComponent("core-catalog"),
          cache: cache?.appendingPathComponent("core-catalog"), cancellation: journal.cancellation)
        coreSelection = try coreRefs.select(nil)
      }
      let core = try await GitSnapshot.run(
        repository: sources.repository("Homebrew/homebrew-core"),
        expectedCommit: coreSelection.commitID, pinned: coreSelection,
        output: output.appendingPathComponent("core"), cache: cache?.appendingPathComponent("core"),
        cancellation: journal.cancellation)
      let resources = output.appendingPathComponent("resources")
      guard let probe = scripts.last,
        try SafeFile.sha256(output.appendingPathComponent("brew/checkout/Library/Homebrew/brew.sh"))
          == probe.sha256
      else {
        throw MisoError.invalid("Homebrew compatibility probe differs from the pinned checkout")
      }
      try SafeFile.makeDirectory(resources)
      let inputs = resources.appendingPathComponent("homebrew-sources")
      try SafeFile.makeDirectory(inputs, mode: 0o755)
      for name in ["brew", "core"] {
        try FileManager.default.moveItem(
          at: output.appendingPathComponent(name + "/checkout"),
          to: inputs.appendingPathComponent(name))
      }
      let vendor = try GuestVolume(inputs).directory("brew/Library/Homebrew/vendor").url
      guard
        try SafeFile.sha256(vendor.appendingPathComponent("portable-ruby-version"))
          == selected.2.vendorVersion.sha256,
        try SafeFile.sha256(vendor.appendingPathComponent("portable-ruby-arm64-darwin"))
          == selected.2.vendorPlatform.sha256
      else { throw MisoError.invalid("Portable Ruby probe differs from pinned Homebrew source") }
      let rubyVersion = try HomebrewRubyProbe.rubyVersion(
        SafeFile.read(vendor.appendingPathComponent("portable-ruby-version"), limit: 64))
      let rubySHA = try assignment(
        "ruby_SHA",
        in: SafeFile.read(vendor.appendingPathComponent("portable-ruby-arm64-darwin"), limit: 4096))
      try SafeFile.validateSHA256(rubySHA)
      let rubyTar = inputs.appendingPathComponent("portable-ruby.tar.gz")
      try Artifacts.copy(
        Artifacts.resolve(selected.2.payload, under: output, cancellation: journal.cancellation),
        to: rubyTar, maximumBytes: 64 << 20, cancellation: journal.cancellation)
      let rubyRecord = try Artifacts.record(rubyTar, relativeTo: output)
      guard rubyRecord.sha256 == rubySHA else {
        throw MisoError.invalid("Portable Ruby differs from pinned Homebrew digest")
      }
      let rubyMinimum = try MacOSVersion(selected.2.minimumMacOS)
      guard try rubyMinimum <= MacOSVersion(target.version) else {
        throw MisoError.unsupported("Portable Ruby excludes target macOS")
      }
      try SafeFile.writeNew(
        JSON.encode(Ruby(version: rubyVersion, sha256: rubySHA, bytes: rubyRecord.bytes)),
        to: inputs.appendingPathComponent("portable-ruby.json"))
      let inventory = try BaseInputArchive.inventory(inputs, cancellation: journal.cancellation)
      let manifest = BaseInputArchive.Manifest(
        schemaVersion: 1, target: target, host: journal.record.host, createdAt: Date(),
        resources: [
          .init(
            name: "homebrew-sources", origin: "Homebrew/brew@\(brew.selection.commitID)",
            entries: inventory)
        ], completeBaseInputs: false)
      let archive = try JSON.encode(manifest)
      try SafeFile.writeNew(archive, to: output.appendingPathComponent("archive.json"))
      _ = try BaseInputArchive.verify(output, cancellation: journal.cancellation)
      let receipt = Receipt(
        schemaVersion: 1, target: target, requestedVersion: version,
        requestedCoreRevision: coreRevision, sources: sources,
        version: selected.0,
        brew: brew, core: core, compatibility: scripts, rubyProbes: rubyProbes,
        portableRuby: rubyRecord,
        portableRubyMinimumMacOS: rubyMinimum.description,
        archiveSHA256: SafeFile.sha256(archive), installationVerified: false)
      if let previous {
        guard receipt.version == previous.version, receipt.brew == previous.brew,
          receipt.core == previous.core,
          receipt.compatibility == previous.compatibility,
          receipt.portableRuby == previous.portableRuby
        else {
          throw MisoError.invalid("Replayed Homebrew bootstrap inputs changed")
        }
      }
      try SafeFile.writeNew(
        JSON.encode(receipt), to: output.appendingPathComponent("resolution.json"))
      try journal.finish(receipt)
      return receipt
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

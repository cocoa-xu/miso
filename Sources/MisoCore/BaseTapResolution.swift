import Darwin
import Foundation

public enum BaseTapResolution {
  struct Item: Codable {
    let request: PackageRequest
    let profile: TapFormula.Profile
    let formula: TapFormula
    let snapshot: GitSnapshot.Receipt
    let payload: ImageBundle.FileRecord
    let minimumMacOS: String
  }

  struct Rejection: Codable {
    let name: String
    let profile: TapFormula.Profile
    let commit: String
    let version: String
    let minimumMacOS: String
  }

  public struct Receipt: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let sources: BaseSourceConfiguration
    let items: [Item]
    let metadata: [ImageBundle.FileRecord]
    let rejected: [Rejection]
    let installationVerified: Bool
  }

  private struct Candidate {
    let commit: String
    let formula: TapFormula
    let payload: ImageBundle.FileRecord
    let minimum: String
    let source: Data
  }

  static func commits(_ data: Data) throws -> [String] {
    guard data.count <= 4 << 20,
      let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      entries.count <= 100
    else {
      throw MisoError.invalid("Invalid tap formula history")
    }
    return try entries.map {
      guard let sha = $0["sha"] as? String else {
        throw MisoError.invalid("Missing tap history commit")
      }
      _ = try GitRemote.objectID(sha)
      return sha
    }
  }

  public static func run(
    requests: [PackageRequest], target: MacOSRelease, sources: BaseSourceConfiguration = .init(),
    output: URL, cache: URL? = nil, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    try sources.validate()
    guard (1...3).contains(requests.count), Set(requests.map(\.name)).count == requests.count else {
      throw MisoError.invalid("Duplicate or excessive tap requests")
    }
    for request in requests {
      try request.validate()
      guard !TapFormula.Profile.options(for: request.name).isEmpty else {
        throw MisoError.unsupported("Tap formula: \(request.name)")
      }
      if let version = request.version { _ = try StableVersion(version) }
    }
    let previous = try cache.map {
      try JSON.read(Receipt.self, from: GuestVolume($0).path("resolution.json"))
    }
    if let previous {
      guard previous.schemaVersion == 1, previous.target == target, previous.sources == sources,
        previous.items.map(\.request) == requests, previous.metadata.count <= 8100
      else {
        throw MisoError.invalid("Tap cache differs from requested inputs")
      }
    }
    let journal = try ExecutionJournal(
      output: output, operation: "resolve-base-taps", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: target)
      for directory in [
        "metadata", "payloads", "git", "catalogs", "resources", "resources/tap-sources",
      ] {
        try SafeFile.makeDirectory(output.appendingPathComponent(directory), mode: 0o755)
      }
      var metadata: [ImageBundle.FileRecord] = []
      if let previous, let cache {
        for record in previous.metadata {
          guard record.path.hasPrefix("metadata/"), record.bytes <= 4 << 20 else {
            throw MisoError.invalid("Invalid tap metadata cache record")
          }
          try Artifacts.copy(
            Artifacts.resolve(record, under: cache, cancellation: journal.cancellation),
            to: Artifacts.makeParents(for: record.path, under: output), maximumBytes: record.bytes,
            cancellation: journal.cancellation)
        }
        metadata = previous.metadata
      }
      var items: [Item] = []
      var taps: [BaseTapInputs.Tap] = []
      var rejected = previous?.rejected ?? []
      for (index, request) in requests.enumerated() {
        let profiles = TapFormula.Profile.options(for: request.name)
        let profile: TapFormula.Profile
        let selected: Candidate
        if let previous, let cache {
          let item = previous.items[index]
          guard profiles.contains(item.profile) else {
            throw MisoError.invalid("Cached tap profile differs from requested package")
          }
          profile = item.profile
          let relative = "resources/tap-sources/\(request.name)/\(profile.path)"
          let source = try SafeFile.read(GuestVolume(cache).path(relative), limit: 256 << 10)
          let formula = try TapFormula(source, profile: profile)
          guard formula == item.formula, item.payload.path.hasPrefix("payloads/"),
            item.payload.bytes <= 128 << 20
          else {
            throw MisoError.invalid("Cached tap formula changed")
          }
          let payload = output.appendingPathComponent(try SafeFile.relativePath(item.payload.path))
          try Artifacts.copy(
            Artifacts.resolve(item.payload, under: cache, cancellation: journal.cancellation),
            to: payload,
            maximumBytes: 128 << 20, cancellation: journal.cancellation)
          selected = Candidate(
            commit: item.snapshot.selection.commitID, formula: formula, payload: item.payload,
            minimum: item.minimumMacOS, source: source)
        } else {
          var resolved: (TapFormula.Profile, Candidate)?
          for option in profiles {
            let remote = try await GitReferences.run(
              repository: option.repository, prefix: "HEAD",
              output: output.appendingPathComponent("catalogs/\(option.rawValue)"),
              cancellation: journal.cancellation)
            let head = try remote.select(nil).commitID
            if let candidate = try await resolve(
              request, profile: option, head: head, target: target, output: output,
              metadata: &metadata, rejected: &rejected, cancellation: journal.cancellation)
            {
              resolved = (option, candidate)
              break
            }
          }
          guard let resolved else {
            throw MisoError.unsupported(
              "No compatible requested tap release found within preserved formula history: \(request.name)"
            )
          }
          (profile, selected) = resolved
        }
        if let wanted = request.version, wanted != selected.formula.version {
          throw MisoError.invalid("Tap version differs from explicit request")
        }
        let pin = GitRemote.Selection(
          reference: "HEAD", objectID: selected.commit, commitID: selected.commit)
        let snapshot = try await GitSnapshot.run(
          repository: sources.repository(profile.repository), expectedCommit: selected.commit,
          pinned: pin, output: output.appendingPathComponent("git/\(request.name)"),
          cache: cache?.appendingPathComponent("git/\(request.name)"),
          cancellation: journal.cancellation)
        let checkout = output.appendingPathComponent("git/\(request.name)/checkout")
        guard
          try SafeFile.read(GuestVolume(checkout).path(profile.path), limit: 256 << 10)
            == selected.source
        else {
          throw MisoError.invalid("Tap formula probe differs from pinned checkout")
        }
        let root = output.appendingPathComponent("resources/tap-sources/\(request.name)")
        try FileManager.default.moveItem(at: checkout, to: root)
        let payload = try Artifacts.resolve(
          selected.payload, under: output, cancellation: journal.cancellation)
        guard selected.payload.sha256 == selected.formula.sha256 else {
          throw MisoError.invalid("Tap payload checksum differs from formula")
        }
        let minimum = try inspect(payload, profile: profile, cancellation: journal.cancellation)
        guard minimum.description == selected.minimum, try minimum <= MacOSVersion(target.version)
        else {
          throw MisoError.invalid("Tap executable does not match compatibility selection")
        }
        items.append(
          Item(
            request: request, profile: profile, formula: selected.formula, snapshot: snapshot,
            payload: selected.payload, minimumMacOS: minimum.description))
        taps.append(
          .init(
            name: profile.tap, revision: snapshot.selection.commitID, resource: "tap-sources",
            path: request.name,
            formulas: [
              .init(
                name: request.name, version: selected.formula.version,
                revision: selected.formula.revision, payload: selected.payload)
            ]))
      }
      let inventory = try BaseInputArchive.inventory(
        output.appendingPathComponent("resources/tap-sources"), cancellation: journal.cancellation)
      let manifest = BaseInputArchive.Manifest(
        schemaVersion: 1, target: target, host: journal.record.host, createdAt: Date(),
        resources: [.init(name: "tap-sources", origin: nil, entries: inventory)],
        completeBaseInputs: false)
      let archive = output.appendingPathComponent("archive.json")
      try SafeFile.writeNew(JSON.encode(manifest), to: archive)
      let plan = BaseTapInputs.Plan(
        schemaVersion: 1, target: target,
        archive: try Artifacts.record(archive, relativeTo: output), taps: taps)
      let planURL = output.appendingPathComponent("plan.json")
      try SafeFile.writeNew(JSON.encode(plan), to: planURL)
      _ = try BaseTapInputs.verify(
        plan: planURL, inputs: output, cancellation: journal.cancellation)
      let receipt = Receipt(
        schemaVersion: 1, target: target, sources: sources, items: items, metadata: metadata,
        rejected: rejected, installationVerified: false)
      try SafeFile.writeNew(
        JSON.encode(receipt), to: output.appendingPathComponent("resolution.json"))
      try journal.finish(receipt)
      return receipt
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  static func inspect(_ payload: URL, profile: TapFormula.Profile, cancellation: CancellationToken?)
    throws -> MacOSVersion
  {
    let entries = try TarPayload.inspect(payload, cancellation: cancellation)
    guard
      entries.contains(where: {
        $0.path == profile.executable && $0.kind == S_IFREG && $0.mode & 0o111 != 0
          && $0.link == nil && $0.hardlink == nil
      })
    else {
      throw MisoError.invalid("Missing tap executable")
    }
    return try TapFormula.minimumMacOS(
      TarPayload.file(
        payload, path: profile.executable, maximumBytes: 128 << 20, cancellation: cancellation))
  }

  private static func resolve(
    _ request: PackageRequest, profile: TapFormula.Profile, head: String, target: MacOSRelease,
    output: URL,
    metadata: inout [ImageBundle.FileRecord], rejected: inout [Rejection],
    cancellation: CancellationToken
  ) async throws -> Candidate? {
    var candidates = [head]
    var seenCommits = Set<String>()
    var seenPayloads = Set<String>()
    var page = 0
    var cursor = 0
    func preserve(_ data: Data, name: String) throws -> ImageBundle.FileRecord {
      let path = output.appendingPathComponent("metadata/\(profile.rawValue)-\(name)")
      try SafeFile.writeNew(data, to: path)
      return try Artifacts.record(path, relativeTo: output)
    }
    while seenCommits.count < 1000 {
      try cancellation.check()
      if cursor == candidates.count {
        page += 1
        guard page <= 10 else { break }
        var url = URLComponents(
          string: "https://api.github.com/repos/\(profile.repository)/commits")!
        url.queryItems = [
          .init(name: "sha", value: head), .init(name: "path", value: profile.path),
          .init(name: "per_page", value: "100"), .init(name: "page", value: String(page)),
        ]
        let data = try await HTTPData.githubAPI(
          url.url!, maximumBytes: 4 << 20, cancellation: cancellation)
        metadata.append(try preserve(data, name: "history-\(page).json"))
        let history = try commits(data)
        if history.isEmpty { break }
        candidates += history
      }
      let commit = candidates[cursor]
      cursor += 1
      guard seenCommits.insert(commit).inserted else { continue }
      let source = try await HTTPData.get(
        URL(
          string:
            "https://raw.githubusercontent.com/\(profile.repository)/\(commit)/\(profile.path)")!,
        maximumBytes: 256 << 10, cancellation: cancellation)
      metadata.append(try preserve(source, name: commit + ".rb"))
      let formula = try TapFormula(source, profile: profile)
      if let version = request.version, version != formula.version { continue }
      guard seenPayloads.insert(formula.sha256).inserted else { continue }
      let path = output.appendingPathComponent(
        "payloads/\(request.name)-\(formula.version)-\(formula.sha256.prefix(12)).tar.gz")
      try await HTTPFile.get(
        formula.downloadURL(profile: profile), to: path, maximumBytes: 128 << 20,
        cancellation: cancellation,
        redirects: .githubRelease)
      let record = try Artifacts.record(path, relativeTo: output)
      guard record.sha256 == formula.sha256 else {
        throw MisoError.invalid("Tap download differs from formula digest")
      }
      let minimum = try inspect(path, profile: profile, cancellation: cancellation)
      if try minimum <= MacOSVersion(target.version) {
        return Candidate(
          commit: commit, formula: formula, payload: record, minimum: minimum.description,
          source: source)
      }
      let rejection = Rejection(
        name: request.name, profile: profile, commit: commit, version: formula.version,
        minimumMacOS: minimum.description)
      rejected.append(rejection)
      metadata.append(try preserve(JSON.encode(rejection), name: commit + "-rejected.json"))
      try FileManager.default.removeItem(at: path)
    }
    return nil
  }
}

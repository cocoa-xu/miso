import Foundation

public enum BaseRubyResolution {
  public struct Receipt: Encodable {
    let schemaVersion: Int
    let target: MacOSRelease
    let requestedVersion: String?
    let additionalVersions: [String]
    let resolutionSHA256: String
    let bottle: ImageBundle.FileRecord
    let definitions: [ImageBundle.FileRecord]
    let sources: [RubyBuildDefinition.Source]
    let plan: BaseRuby.Plan
    let installationVerified: Bool
    let runtimeCompatibilityVerified: Bool
  }

  public static func run(
    configuration: BaseConfiguration, resolution: URL, bottles: URL, output: URL,
    cache: URL? = nil, jobs: Int = 4, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    try configuration.validate()
    guard (1...8).contains(jobs), configuration.additionalRubyVersions.count < 8 else {
      throw MisoError.invalid("Invalid Ruby build count or concurrency")
    }
    let selection = try HomebrewBottleInputs.load(
      resolution: resolution, bottles: bottles, names: ["ruby-build"], cancellation: cancellation)
    _ = try RestoreProfile.select(selection.target)
    guard let bottle = selection.payloads.first(where: { $0.formula.name == "ruby-build" }) else {
      throw MisoError.invalid("Missing ruby-build bottle")
    }
    let archive = try Artifacts.resolve(bottle.archive, under: bottles, cancellation: cancellation)
    let prefix = "ruby-build/\(bottle.formula.kegVersion)/share/ruby-build/"
    let entries = try TarPayload.inspect(archive, pathPrefix: "Cellar", cancellation: cancellation)
    let names = entries.filter { $0.path.hasPrefix(prefix) }.map {
      String($0.path.dropFirst(prefix.count))
    }
    let primary = try RubyBuildDefinition.versions(names, requested: configuration.rubyVersion)[0]
    guard !configuration.additionalRubyVersions.contains(primary) else {
      throw MisoError.invalid("Additional Ruby duplicates the selected primary version")
    }
    let versions = [primary] + configuration.additionalRubyVersions
    for version in versions { _ = try RubyBuildDefinition.versions(names, requested: version) }
    let cached = try cache.map { try GuestVolume($0) }
    let journal = try ExecutionJournal(
      output: output, operation: "resolve-base-ruby", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: selection.target)
      try SafeFile.makeDirectory(output.appendingPathComponent("definitions"))
      var definitions: [ImageBundle.FileRecord] = []
      var sources: [RubyBuildDefinition.Source] = []
      var payloads: [String: ImageBundle.FileRecord] = [:]
      var builds: [BaseRuby.Build] = []
      for version in versions {
        let bytes = try TarPayload.file(
          archive, path: prefix + version, maximumBytes: 16_384, cancellation: journal.cancellation)
        let definition = try RubyBuildDefinition(bytes, version: version)
        let file = output.appendingPathComponent("definitions/" + version)
        try SafeFile.writeNew(bytes, to: file)
        definitions.append(try Artifacts.record(file, relativeTo: output))
        let ssl = try selection.payloads.filter {
          guard
            $0.formula.name.range(
              of: #"\Aopenssl(@[0-9]+(\.[0-9]+)*)?\z"#, options: .regularExpression) != nil
          else { return false }
          return try definition.acceptsOpenSSL($0.formula.version)
        }.sorted { try StableVersion($0.formula.version) > StableVersion($1.formula.version) }.first
        let needed = [definition.ruby] + (ssl == nil ? [definition.openssl] : [])
        var records: [ImageBundle.FileRecord] = []
        for source in needed {
          if let existing = payloads[source.name] {
            guard existing.sha256 == source.sha256 else {
              throw MisoError.invalid("Conflicting Ruby source identities")
            }
            records.append(existing)
            continue
          }
          let destination = output.appendingPathComponent(source.name)
          if let cached {
            try Artifacts.copy(
              cached.path(source.name), to: destination, maximumBytes: 256 << 20,
              cancellation: journal.cancellation)
          } else {
            try await HTTPFile.get(
              source.url, to: destination, maximumBytes: 256 << 20,
              cancellation: journal.cancellation,
              redirects: HTTPData.isGitHubReleaseURL(source.url) ? .githubRelease : .reject)
          }
          let record = try Artifacts.record(destination, relativeTo: output)
          guard record.sha256 == source.sha256 else {
            throw MisoError.invalid("Ruby source checksum differs from ruby-build definition")
          }
          records.append(record)
          payloads[source.name] = record
          sources.append(source)
        }
        builds.append(.init(version: version, opensslFormula: ssl?.formula.name, sources: records))
      }
      let plan = BaseRuby.Plan(
        schemaVersion: 1, target: selection.target, builds: builds, defaultVersion: primary,
        jobs: jobs)
      guard try SafeFile.sha256(archive) == bottle.archive.sha256,
        try SafeFile.sha256(resolution.appendingPathComponent("resolution.json"))
          == selection.resolutionSHA256
      else { throw MisoError.invalid("Ruby resolution inputs changed during selection") }
      let planURL = output.appendingPathComponent("plan.json")
      try SafeFile.writeNew(JSON.encode(plan), to: planURL)
      _ = try BaseRuby.verify(plan: planURL, inputs: output, cancellation: journal.cancellation)
      let receipt = Receipt(
        schemaVersion: 1, target: selection.target, requestedVersion: configuration.rubyVersion,
        additionalVersions: configuration.additionalRubyVersions,
        resolutionSHA256: selection.resolutionSHA256, bottle: bottle.archive,
        definitions: definitions, sources: sources, plan: plan,
        installationVerified: false, runtimeCompatibilityVerified: false)
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

import Foundation

public enum BaseGCMResolution {
  struct Cask {
    let version: String
    let packageURL: URL
    let packageSHA256: String
    let recipeURL: URL
    let recipeSHA256: String
    let metadata: Data

    init(_ bytes: Data, target: MacOSRelease, requested: String?) throws {
      _ = try RestoreProfile.select(target)
      guard bytes.count <= 1 << 20,
        let original = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        original["token"] as? String == "git-credential-manager"
      else { throw MisoError.invalid("Invalid credential manager cask metadata") }
      let tag = try HomebrewResolution.tag(for: target)
      let variation = (original["variations"] as? [String: [String: Any]])?[tag] ?? [:]
      let value = original.merging(variation) { _, new in new }
      guard value["disabled"] as? Bool == false,
        let version = value["version"] as? String,
        version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil,
        let digest = value["sha256"] as? String,
        let url = value["url"] as? String,
        let commit = value["tap_git_head"] as? String,
        commit.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil,
        value["ruby_source_path"] as? String == "Casks/g/git-credential-manager.rb",
        let recipeSHA = (value["ruby_source_checksum"] as? [String: Any])?["sha256"] as? String,
        let dependencies = value["depends_on"] as? [String: Any],
        Set(dependencies.keys).isSubset(of: ["macos"])
      else { throw MisoError.unsupported("Unsupported credential manager cask") }
      _ = try StableVersion(version)
      try SafeFile.validateSHA256(digest)
      try SafeFile.validateSHA256(recipeSHA)
      if let requested {
        _ = try StableVersion(requested)
        guard requested == version else {
          throw MisoError.unsupported("Requested GCM version is absent from this cask snapshot")
        }
      }
      if let requirements = dependencies["macos"] {
        try Self.requireCompatibleMacOS(requirements, target: MacOSVersion(target.version))
      }
      let expected =
        "https://github.com/git-ecosystem/git-credential-manager/releases/download/v\(version)/gcm-osx-arm64-\(version).pkg"
      guard url == expected else {
        throw MisoError.invalid("Unexpected credential manager package URL")
      }
      self.version = version
      packageURL = URL(string: expected)!
      packageSHA256 = digest
      recipeURL = URL(
        string:
          "https://raw.githubusercontent.com/Homebrew/homebrew-cask/\(commit)/Casks/g/git-credential-manager.rb"
      )!
      recipeSHA256 = recipeSHA
      metadata = try JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    private static func requireCompatibleMacOS(_ value: Any, target: MacOSVersion) throws {
      guard let requirements = value as? [String: [String]], requirements.count == 1,
        let versions = requirements[">="], versions.count == 1
      else { throw MisoError.unsupported("Unsupported cask macOS requirements") }
      let value = versions[0]
      let minimum = try MacOSVersion(value.contains(".") ? value : value + ".0")
      guard target >= minimum else {
        throw MisoError.unsupported("Credential manager cask excludes target macOS")
      }
    }
  }

  public struct Receipt: Encodable {
    let schemaVersion: Int
    let target: MacOSRelease
    let requestedVersion: String?
    let cask: ImageBundle.FileRecord
    let packageURL: URL
    let recipeURL: URL
    let plan: BaseGCMInputs.Plan
    let installationVerified: Bool
    let signaturesVerified: Bool
  }

  public static func run(
    target: MacOSRelease, version: String? = nil, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    if let version { _ = try StableVersion(version) }
    let cached = try cache.map { try GuestVolume($0) }
    let journal = try ExecutionJournal(
      output: output, operation: "resolve-base-gcm", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: target)
      let bytes: Data
      if let cached {
        bytes = try SafeFile.read(cached.path("cask.json"), limit: 1 << 20)
      } else {
        bytes = try await HTTPData.get(
          URL(string: "https://formulae.brew.sh/api/cask/git-credential-manager.json")!,
          maximumBytes: 1 << 20, cancellation: journal.cancellation)
      }
      let cask = try Cask(bytes, target: target, requested: version)
      try SafeFile.writeNew(bytes, to: output.appendingPathComponent("cask.json"))
      try SafeFile.writeNew(cask.metadata, to: output.appendingPathComponent("metadata.json"))
      for (name, url, checksum, limit) in [
        ("recipe.rb", cask.recipeURL, cask.recipeSHA256, UInt64(1 << 20)),
        ("git-credential-manager.pkg", cask.packageURL, cask.packageSHA256, UInt64(512 << 20)),
      ] {
        let destination = output.appendingPathComponent(name)
        if let cached {
          try Artifacts.copy(
            cached.path(name), to: destination, maximumBytes: limit,
            cancellation: journal.cancellation)
        } else {
          try await HTTPFile.get(
            url, to: destination, maximumBytes: limit, cancellation: journal.cancellation,
            redirects: HTTPData.isGitHubReleaseURL(url) ? .githubRelease : .reject)
        }
        guard try SafeFile.sha256(destination) == checksum else {
          throw MisoError.invalid("Credential manager input differs from cask checksum: \(name)")
        }
      }
      let plan = try BaseGCMInputs.Plan(
        schemaVersion: 1, target: target, version: cask.version,
        package: Artifacts.record(
          output.appendingPathComponent("git-credential-manager.pkg"), relativeTo: output),
        recipe: Artifacts.record(output.appendingPathComponent("recipe.rb"), relativeTo: output),
        metadata: Artifacts.record(
          output.appendingPathComponent("metadata.json"), relativeTo: output))
      let planURL = output.appendingPathComponent("plan.json")
      try SafeFile.writeNew(JSON.encode(plan), to: planURL)
      _ = try BaseGCMInputs.verify(
        plan: planURL, inputs: output, cancellation: journal.cancellation)
      let receipt = Receipt(
        schemaVersion: 1, target: target, requestedVersion: version,
        cask: try Artifacts.record(output.appendingPathComponent("cask.json"), relativeTo: output),
        packageURL: cask.packageURL, recipeURL: cask.recipeURL, plan: plan,
        installationVerified: false, signaturesVerified: false)
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

import Foundation

public enum BasePackageResolution {
  public struct Receipt: Encodable {
    let schemaVersion: Int
    let target: MacOSRelease
    let requests: [PackageRequest]
    let requestedBundler: String?
    let plan: BasePackageInputs.Plan
    let metadata: [ImageBundle.FileRecord]
    let payloads: [ImageBundle.FileRecord]
    let rejected: [Rejection]
    let payloadsIncluded: Bool
    let installationVerified: Bool
    let completeBaseResolution: Bool
  }

  struct Rejection: Encodable {
    let name: String
    let version: String
    let reason: String
  }

  static func minimumMacOS(_ binary: Data) throws -> MacOSVersion {
    let image = try MachOImage(binary)
    guard image.type == 2, let value = image.minimumMacOS, value >> 16 >= 11 else {
      throw MisoError.invalid("Expected an arm64 macOS executable with a deployment target")
    }
    return try MacOSVersion("\(value >> 16).\((value >> 8) & 255).\(value & 255)")
  }

  public static func run(
    requests: [PackageRequest], bundlerVersion: String? = nil, target: MacOSRelease,
    rubyVersion: String, nodeFormula: String, runtimes: BasePackageInputs.Runtimes,
    output: URL, cache: URL? = nil, cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    _ = try StableVersion(rubyVersion)
    try runtimes.validate()
    if let bundlerVersion { _ = try StableVersion(bundlerVersion) }
    guard !requests.isEmpty, requests.count <= 2,
      Set(requests.map(\.name)).count == requests.count,
      requests.allSatisfy({ ["yarn", "pnpm"].contains($0.name) }),
      nodeFormula.range(of: #"\Anode(@[0-9]+)?\z"#, options: .regularExpression) != nil
    else { throw MisoError.invalid("Expected unique yarn/pnpm requests and a Node formula") }
    for request in requests {
      try request.validate()
      if let version = request.version { _ = try StableVersion(version) }
    }
    let cached = try cache.map { try GuestVolume($0) }
    let journal = try ExecutionJournal(
      output: output, operation: "resolve-base-packages", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: target)
      try journal.setMetadata("runtimes", value: runtimes)
      for name in ["metadata", "payloads"] {
        try SafeFile.makeDirectory(output.appendingPathComponent(name))
      }
      var registry = BasePackageRegistry(
        output: output, cache: cached, cancellation: journal.cancellation)
      var rejected: [Rejection] = []
      let index = try await registry.document(
        "bundler-index",
        url: URL(string: "https://rubygems.org/api/v1/versions/bundler.json")!)
      let gemCandidates = try PackageRegistryMetadata.gemVersions(index, requested: bundlerVersion)
      var selectedGem: PackageRegistryMetadata.GemVersion?
      for candidate in gemCandidates {
        if try candidate.compatible(ruby: rubyVersion, rubygems: runtimes.rubygems) {
          selectedGem = candidate
          break
        }
        rejected.append(
          .init(name: "bundler", version: candidate.number, reason: "runtime-requirement"))
      }
      guard let selectedGem else {
        throw MisoError.unsupported("No requested Bundler release supports the target runtimes")
      }
      let gemKey = "bundler-" + selectedGem.number
      let gemData = try await registry.document(
        gemKey,
        url: URL(
          string: "https://rubygems.org/api/v2/rubygems/bundler/versions/\(selectedGem.number).json"
        )!)
      let gem = try JSONDecoder().decode(PackageRegistryMetadata.Gem.self, from: gemData)
      try gem.validate(selectedGem)
      let gemPayload = try await registry.payload("payloads/" + gemKey + ".gem", url: gem.gemURI)
      let gemFile = try SafeFile.openRegular(gemPayload)
      defer { try? gemFile.close() }
      guard try SafeFile.sha256(gemFile, cancellation: journal.cancellation) == gem.sha else {
        throw MisoError.invalid("Bundler payload checksum differs from registry")
      }
      let bundler = BasePackageInputs.Package(
        name: "bundler", version: gem.version,
        metadata: try Artifacts.record(
          output.appendingPathComponent("metadata/" + gemKey + ".json"), relativeTo: output),
        payload: try Artifacts.record(gemPayload, relativeTo: output))

      var packages: [BasePackageInputs.Package] = []
      var incompatibleNative: [String: String] = [:]
      for request in requests {
        let candidates = try PackageRegistryMetadata.npmVersions(
          await registry.npmDocument(request.name), request: request)
        var selected: [BasePackageInputs.Package]?
        var payloadAttempts = 0
        for (candidate, bytes) in candidates {
          if try !candidate.compatible(with: runtimes) {
            rejected.append(
              .init(name: request.name, version: candidate.version, reason: "runtime-or-platform"))
            continue
          }
          try candidate.validate()
          var resolved: [BasePackageInputs.Package] = []
          if candidate.optionalDependencies?.isEmpty == false,
            candidate.optionalDependencies?[PackageRegistryMetadata.nativePNPM] == nil
          {
            rejected.append(
              .init(
                name: request.name, version: candidate.version, reason: "missing-arm64-component"))
            continue
          }
          if let nativeVersion = candidate.optionalDependencies?[PackageRegistryMetadata.nativePNPM]
          {
            if let reason = incompatibleNative[nativeVersion] {
              rejected.append(.init(name: request.name, version: candidate.version, reason: reason))
              continue
            }
            let native = try PackageRegistryMetadata.npmVersions(
              await registry.npmDocument(PackageRegistryMetadata.nativePNPM),
              request: .init(name: PackageRegistryMetadata.nativePNPM, version: nativeVersion))
            guard native.count == 1, try native[0].0.compatible(with: runtimes) else {
              let reason = "missing-or-incompatible-arm64-component"
              incompatibleNative[nativeVersion] = reason
              rejected.append(.init(name: request.name, version: candidate.version, reason: reason))
              continue
            }
            payloadAttempts += 1
            guard payloadAttempts <= 32 else {
              throw MisoError.unsupported("Native pnpm compatibility search exceeds limit")
            }
            do {
              resolved.append(
                try await registry.npmPayload(native[0].0, bytes: native[0].1, target: target))
            } catch BasePackageRegistry.CompatibilityError.minimumMacOS {
              let reason = "native-minimum-macos"
              incompatibleNative[nativeVersion] = reason
              rejected.append(.init(name: request.name, version: candidate.version, reason: reason))
              continue
            }
          }
          resolved.append(try await registry.npmPayload(candidate, bytes: bytes, target: target))
          selected = resolved
          break
        }
        guard let selected else {
          throw MisoError.unsupported("No requested compatible release of \(request.name)")
        }
        packages += selected
      }
      var plan = BasePackageInputs.Plan(
        schemaVersion: 1, target: target, rubyVersion: rubyVersion,
        nodeFormula: nodeFormula, bundler: bundler, npm: packages)
      plan.runtimes = runtimes
      let planURL = output.appendingPathComponent("plan.json")
      try SafeFile.writeNew(JSON.encode(plan), to: planURL)
      _ = try BasePackageInputs.verify(
        plan: planURL, inputs: output, cancellation: journal.cancellation)
      let receipt = Receipt(
        schemaVersion: 1, target: target, requests: requests, requestedBundler: bundlerVersion,
        plan: plan, metadata: try registry.records("metadata"),
        payloads: try registry.records("payloads"),
        rejected: rejected,
        payloadsIncluded: true, installationVerified: false, completeBaseResolution: false)
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

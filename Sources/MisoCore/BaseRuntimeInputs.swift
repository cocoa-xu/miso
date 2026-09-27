import Foundation

public enum BaseRuntimeInputs {
  public struct Receipt: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let nodeFormula: String
    let rubyVersion: String
    let runtimes: BasePackageInputs.Runtimes
    let nodeMinimumMacOS: String
    let resolutionSHA256: String
    let nodeBottle: ImageBundle.FileRecord
    let rubyPlanSHA256: String
    let rubySource: ImageBundle.FileRecord
    let executedCode: Bool
  }

  static func nodeVersion(_ data: Data) throws -> String {
    guard data.count <= 1 << 20, let text = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid Node version header")
    }
    let version = try ["MAJOR", "MINOR", "PATCH"].map { component in
      try capture(
        #"(?m)^#define[ \t]+NODE_"# + component + #"_VERSION[ \t]+([0-9]+)[ \t]*\r?$"#,
        in: text)
    }.joined(separator: ".")
    _ = try StableVersion(version)
    return version
  }

  static func npmVersion(_ data: Data, node: String) throws -> String {
    struct Manifest: Decodable {
      let name: String
      let version: String
      let engines: [String: String]
    }
    guard data.count <= 1 << 20 else { throw MisoError.invalid("npm manifest exceeds limit") }
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    guard manifest.name == "npm", let range = manifest.engines["node"],
      try VersionRequirement(range, syntax: .npm).contains(node)
    else { throw MisoError.invalid("Bundled npm does not support the selected Node version") }
    _ = try StableVersion(manifest.version)
    return manifest.version
  }

  static func rubyGemsVersion(_ data: Data) throws -> String {
    guard data.count <= 1 << 20, let text = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid RubyGems source")
    }
    let version = try capture(
      #"(?m)^module Gem[ \t]*\r?\n[ \t]+VERSION[ \t]*=[ \t]*(["'])([0-9]+(?:\.[0-9]+){1,3})\1[ \t]*\r?$"#,
      in: text, group: 2)
    _ = try StableVersion(version)
    return version
  }

  private static func capture(_ pattern: String, in text: String, group: Int = 1) throws -> String {
    let matches = try NSRegularExpression(pattern: pattern).matches(
      in: text, range: NSRange(text.startIndex..., in: text))
    guard matches.count == 1, let match = matches.first,
      let range = Range(match.range(at: group), in: text)
    else { throw MisoError.unsupported("Missing or ambiguous runtime version declaration") }
    return String(text[range])
  }

  public static func run(
    resolution: URL, bottles: URL, nodeFormula: String,
    rubyPlan: URL, rubyInputs: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard nodeFormula.range(of: #"\Anode(@[0-9]+)?\z"#, options: .regularExpression) != nil else {
      throw MisoError.invalid("Expected a Node formula")
    }
    let selection = try HomebrewBottleInputs.load(
      resolution: resolution, bottles: bottles, names: [nodeFormula], cancellation: cancellation)
    let planRecord = try Artifacts.record(
      rubyPlan, relativeTo: rubyPlan.deletingLastPathComponent())
    let plan = try BaseRuby.verify(plan: rubyPlan, inputs: rubyInputs, cancellation: cancellation)
    guard plan.target == selection.target,
      let node = selection.payloads.first(where: { $0.formula.name == nodeFormula }),
      let ruby = plan.builds.first(where: { $0.version == plan.defaultVersion })?.sources.first
    else { throw MisoError.invalid("Runtime inputs differ from the selected target") }
    let journal = try ExecutionJournal(
      output: output, operation: "inspect-base-runtimes", cancellation: cancellation)
    do {
      try journal.setMetadata("target", value: selection.target)
      let archive = try Artifacts.resolve(
        node.archive, under: bottles, cancellation: journal.cancellation)
      let prefix = "\(nodeFormula)/\(node.formula.kegVersion)/"
      let version = try nodeVersion(
        TarPayload.file(
          archive, path: prefix + "include/node/node_version.h", maximumBytes: 1 << 20,
          cancellation: journal.cancellation))
      guard version == node.formula.version else {
        throw MisoError.invalid("Node version header differs from the resolved formula")
      }
      let minimum = try BasePackageResolution.minimumMacOS(
        TarPayload.file(
          archive, path: prefix + "bin/node", maximumBytes: 128 << 20,
          cancellation: journal.cancellation))
      guard try MacOSVersion(selection.target.version) >= minimum else {
        throw MisoError.unsupported("Node executable excludes target macOS")
      }
      let npm = try npmVersion(
        TarPayload.file(
          archive, path: prefix + "lib/node_modules/npm/package.json", maximumBytes: 1 << 20,
          cancellation: journal.cancellation), node: version)
      let source = try Artifacts.resolve(
        ruby, under: rubyInputs, cancellation: journal.cancellation)
      let rubygems = try rubyGemsVersion(
        TarPayload.file(
          source, path: "ruby-\(plan.defaultVersion)/lib/rubygems.rb", maximumBytes: 1 << 20,
          cancellation: journal.cancellation))
      guard try SafeFile.sha256(archive) == node.archive.sha256,
        try SafeFile.sha256(source) == ruby.sha256,
        try SafeFile.sha256(rubyPlan) == planRecord.sha256,
        try SafeFile.sha256(resolution.appendingPathComponent("resolution.json"))
          == selection.resolutionSHA256
      else { throw MisoError.invalid("Runtime inputs changed during inspection") }
      let receipt = Receipt(
        schemaVersion: 1, target: selection.target, nodeFormula: nodeFormula,
        rubyVersion: plan.defaultVersion,
        runtimes: .init(node: version, npm: npm, rubygems: rubygems),
        nodeMinimumMacOS: minimum.description, resolutionSHA256: selection.resolutionSHA256,
        nodeBottle: node.archive, rubyPlanSHA256: planRecord.sha256, rubySource: ruby,
        executedCode: false)
      try SafeFile.writeNew(
        JSON.encode(receipt), to: output.appendingPathComponent("runtimes.json"))
      try journal.finish(receipt)
      return receipt
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

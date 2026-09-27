import Darwin
import Foundation

public enum HomebrewBottleInputs {
  struct Payload: Codable {
    let formula: HomebrewResolution.Formula
    let archive: ImageBundle.FileRecord
    let index: ImageBundle.FileRecord
    let tab: JSONValue

    var filename: String {
      let rebuild = formula.bottle.rebuild == 0 ? "" : ".\(formula.bottle.rebuild)"
      return "\(formula.name)--\(formula.kegVersion).\(formula.bottle.tag).bottle\(rebuild).tar.gz"
    }

    var sidecarName: String {
      "\(formula.name)--\(formula.kegVersion).\(formula.bottle.tag).bottle.json"
    }

    var sidecar: JSONValue {
      .object([
        formula.name: .object([
          "bottle": .object([
            "tags": .object([formula.bottle.tag: .object(["tab": tab])])
          ])
        ])
      ])
    }
  }

  public struct Selection: Codable {
    let target: MacOSRelease
    let resolutionSHA256: String
    let payloads: [Payload]
  }

  public static func load(
    resolution: URL, bottles: URL, names: [String], cancellation: CancellationToken?
  ) throws -> Selection {
    let documents = try GuestVolume(resolution)
    let directory = try GuestVolume(bottles)
    let receiptURL = try documents.path("resolution.json")
    let resolutionHash = try SafeFile.sha256(receiptURL)
    let receipt = try JSON.read(HomebrewResolution.Receipt.self, from: receiptURL)
    guard receipt.schemaVersion == 1, !receipt.formulae.isEmpty,
      receipt.formulae.count <= 1024, !receipt.selectedRoots.isEmpty,
      receipt.installOrder
        == (try HomebrewResolution.installOrder(
          receipt.formulae, roots: Array(receipt.selectedRoots.values))),
      Set(receipt.metadata.map(\.path)).count == receipt.metadata.count
    else { throw MisoError.invalid("Invalid Homebrew resolution") }
    for record in receipt.metadata {
      guard record.path.hasPrefix("metadata/") else {
        throw MisoError.invalid("Unexpected formula metadata path")
      }
      _ = try Artifacts.resolve(record, under: resolution, cancellation: cancellation)
    }
    for (name, formula) in receipt.formulae {
      let data = try SafeFile.read(documents.path("metadata/\(name).json"), limit: 8 << 20)
      guard try HomebrewResolution.parse(data, name: name, target: receipt.target) == formula,
        try SafeFile.sha256(documents.path("metadata/\(name).rb")) == formula.sourceSHA256
      else { throw MisoError.invalid("Formula differs from resolution: \(name)") }
    }
    guard Set(names).count == names.count else {
      throw MisoError.invalid("Duplicate bottle selection")
    }
    var selected = Set<String>()
    var pending = names.isEmpty ? Array(receipt.selectedRoots.values) : names
    while let name = pending.popLast() {
      try PackageRequest(name: name).validate()
      guard let formula = receipt.formulae[name] else {
        throw MisoError.invalid("Formula is absent from resolution: \(name)")
      }
      if selected.insert(name).inserted { pending += formula.dependencies }
    }
    var payloads: [Payload] = []
    for name in receipt.installOrder where selected.contains(name) {
      try cancellation?.check()
      let formula = receipt.formulae[name]!
      let archiveURL = try directory.path(name + ".tar.gz")
      let indexURL = try directory.path(name + ".tar.index.json")
      let archive = try Artifacts.record(archiveURL, relativeTo: bottles)
      guard archive.sha256 == formula.bottle.sha256, archive.bytes > 0 else {
        throw MisoError.invalid("Bottle checksum mismatch: \(name)")
      }
      let index = try Artifacts.record(indexURL, relativeTo: bottles)
      let tab = try parseIndex(
        SafeFile.read(indexURL, limit: 8 << 20), formula: formula, bytes: archive.bytes)
      try validateDependencies(tab, formulae: receipt.formulae, selected: selected)
      let entries: [TarPayload.Entry]
      do {
        entries = try TarPayload.inspect(
          archiveURL, pathPrefix: "Cellar", cancellation: cancellation)
      } catch {
        throw MisoError.invalid("Bottle \(name): \(error)")
      }
      let prefix = name + "/" + formula.kegVersion
      guard
        entries.allSatisfy({
          ($0.path == name && $0.kind == S_IFDIR) || $0.path == prefix
            || $0.path.hasPrefix(prefix + "/")
        }), entries.contains(where: { $0.path == prefix + "/.brew/" + name + ".rb" })
      else {
        throw MisoError.invalid("Unexpected bottle layout: \(name)")
      }
      payloads.append(Payload(formula: formula, archive: archive, index: index, tab: tab))
    }
    guard try SafeFile.sha256(receiptURL) == resolutionHash else {
      throw MisoError.invalid("Resolution changed during validation")
    }
    return Selection(target: receipt.target, resolutionSHA256: resolutionHash, payloads: payloads)
  }

  static func parseIndex(
    _ bytes: Data, formula: HomebrewResolution.Formula, bytes size: UInt64
  ) throws -> JSONValue {
    guard let index = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      index["schemaVersion"] as? Int == 2,
      let manifests = index["manifests"] as? [[String: Any]]
    else { throw MisoError.invalid("Invalid bottle OCI index") }
    let rebuild = formula.bottle.rebuild == 0 ? "" : ".\(formula.bottle.rebuild)"
    let reference = "\(formula.kegVersion).\(formula.bottle.tag)\(rebuild)"
    let matches = manifests.compactMap { $0["annotations"] as? [String: String] }.filter {
      $0["org.opencontainers.image.ref.name"] == reference
    }
    guard matches.count == 1, let annotations = matches.first,
      annotations["sh.brew.bottle.digest"] == formula.bottle.sha256,
      annotations["sh.brew.bottle.size"].map({ UInt64($0) == size }) ?? true,
      let tab = annotations["sh.brew.tab"]
    else { throw MisoError.invalid("Bottle OCI identity mismatch: \(formula.name)") }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(tab.utf8))
    guard case .object = value else { throw MisoError.invalid("Invalid bottle tab") }
    return value
  }

  static func validateDependencies(
    _ tab: JSONValue, formulae: [String: HomebrewResolution.Formula], selected: Set<String>
  ) throws {
    guard case .object(let object) = tab,
      case .array(let dependencies) = object["runtime_dependencies"]
    else { throw MisoError.invalid("Missing bottle runtime dependency metadata") }
    for dependency in dependencies {
      guard case .object(let fields) = dependency,
        case .string(let name) = fields["full_name"],
        case .string(let version) = fields["version"],
        case .integer(let revision) = fields["revision"],
        revision >= 0, formulae[name] != nil, selected.contains(name)
      else { throw MisoError.unsupported("Bottle runtime dependencies differ from resolution") }
      try PackageRequest(name: name, version: version).validate()
    }
  }
}

extension HomebrewResolution.Formula {
  var kegVersion: String { revision == 0 ? version : "\(version)_\(revision)" }
}

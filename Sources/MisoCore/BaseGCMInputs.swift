import Darwin
import Foundation

public enum BaseGCMInputs {
  public struct Plan: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let version: String
    let package: ImageBundle.FileRecord
    let recipe: ImageBundle.FileRecord
    let metadata: ImageBundle.FileRecord

    func validate() throws {
      _ = try RestoreProfile.select(target)
      guard schemaVersion == 1,
        version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil,
        Set([package.path, recipe.path, metadata.path]).count == 3
      else { throw MisoError.invalid("Invalid credential manager plan") }
      for (record, limit) in [(package, 512 << 20), (recipe, 1 << 20), (metadata, 1 << 20)] {
        _ = try SafeFile.relativePath(record.path)
        try SafeFile.validateSHA256(record.sha256)
        guard (1...UInt64(limit)).contains(record.bytes) else {
          throw MisoError.invalid("Invalid credential manager input size")
        }
      }
    }
  }

  struct Metadata: Decodable {
    struct Checksum: Decodable { let sha256: String }
    let version: String
    let sha256: String
    let tapRevision: String
    let recipeChecksum: Checksum

    enum CodingKeys: String, CodingKey {
      case version, sha256
      case tapRevision = "tap_git_head"
      case recipeChecksum = "ruby_source_checksum"
    }

    func validate(_ plan: Plan) throws {
      guard version == plan.version, sha256 == plan.package.sha256,
        recipeChecksum.sha256 == plan.recipe.sha256,
        tapRevision.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil
      else { throw MisoError.invalid("Credential manager metadata differs from plan") }
    }
  }

  public static func verify(plan url: URL, inputs: URL, cancellation: CancellationToken? = nil)
    throws -> Plan
  {
    let plan = try JSON.read(Plan.self, from: url)
    try plan.validate()
    for record in [plan.package, plan.recipe, plan.metadata] {
      _ = try Artifacts.resolve(record, under: inputs, cancellation: cancellation)
    }
    try metadata(plan, inputs: inputs).validate(plan)
    return plan
  }

  static func metadata(_ plan: Plan, inputs: URL) throws -> Metadata {
    try JSON.read(Metadata.self, from: GuestVolume(inputs).path(plan.metadata.path))
  }

  public struct Inspection: Encodable {
    let plan: Plan
    let payloadEntries: Int
    let packageSignatureVerified: Bool
    let binarySignatureVerified: Bool
    let packageScriptsExecuted: Bool
  }

  public static func inspect(
    plan url: URL, inputs: URL, output: URL,
    cancellation: CancellationToken? = nil
  ) throws -> Inspection {
    let plan = try verify(plan: url, inputs: inputs, cancellation: cancellation)
    let journal = try ExecutionJournal(
      output: output, operation: "base-gcm-inspect", cancellation: cancellation)
    return try journal.perform {
      let package = try Artifacts.resolve(
        plan.package, under: inputs, cancellation: journal.cancellation)
      let prepared = try BaseGCMPackage.prepare(package, version: plan.version, journal: journal)
      try SafeFile.writeNew(
        JSON.encode(prepared.inventory), to: output.appendingPathComponent("payload.json"))
      _ = try verify(plan: url, inputs: inputs, cancellation: journal.cancellation)
      return Inspection(
        plan: plan, payloadEntries: prepared.inventory.count,
        packageSignatureVerified: true, binarySignatureVerified: true, packageScriptsExecuted: false
      )
    }
  }
}

enum BaseGCMPackage {
  static let identifier = "com.microsoft.gitcredentialmanager"
  static let prefix = "usr/local/share/gcm-core"

  struct Prepared {
    let payload: URL
    let bom: URL
    let inventory: [BaseInputArchive.Entry]
  }

  static func validateInfo(_ data: Data, version: String) throws {
    final class Delegate: NSObject, XMLParserDelegate {
      var root: (String, [String: String])?
      func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
      ) {
        if root == nil { root = (name, attributes) }
      }
    }
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    guard parser.parse(), let (name, attributes) = delegate.root, name == "pkg-info",
      attributes["identifier"] == identifier, attributes["version"] == version,
      attributes["install-location"] == "/" + prefix
    else { throw MisoError.invalid("Unexpected credential manager package identity") }
  }

  static func parseBOM(_ text: String) throws -> [String: PackageInventory.Entry] {
    var entries: [String: PackageInventory.Entry] = [:]
    var sawRoot = false
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 6, fields[0] == "." || fields[0].hasPrefix("./"),
        let mode = mode_t(fields[1], radix: 8), fields[2] == "0", fields[3] == "0",
        mode & 0o7000 == 0, [S_IFDIR, S_IFREG].contains(mode & S_IFMT), fields[5].isEmpty
      else { throw MisoError.invalid("Unsupported credential manager BOM entry") }
      if fields[0] == "." {
        guard !sawRoot, mode == S_IFDIR | 0o755, fields[4].isEmpty else {
          throw MisoError.invalid("Invalid credential manager payload root")
        }
        sawRoot = true
        continue
      }
      let path = try SafeFile.relativePath(String(fields[0].dropFirst(2)))
      let size = fields[4].isEmpty ? nil : UInt64(fields[4])
      guard entries[path] == nil, entries.count < 50_000,
        mode & S_IFMT == S_IFDIR ? fields[4].isEmpty : size != nil && size! <= 512 << 20
      else { throw MisoError.invalid("Invalid credential manager BOM size or path") }
      entries[path] = .init(mode: mode, uid: 0, gid: 0, size: size, link: "", sha256: nil)
    }
    guard sawRoot, entries["git-credential-manager"]?.kind == S_IFREG else {
      throw MisoError.invalid("Incomplete credential manager payload")
    }
    for path in entries.keys {
      var parent = (path as NSString).deletingLastPathComponent
      while !parent.isEmpty {
        guard entries[parent]?.kind == S_IFDIR else {
          throw MisoError.invalid("Missing credential manager payload ancestor")
        }
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    return entries
  }

  static func prepare(_ package: URL, version: String, journal: ExecutionJournal) throws -> Prepared
  {
    try journal.run(
      "gcm-package-signature",
      NativeCommand(.packages, arguments: ["--check-signature", package.path]))
    let expanded = journal.output.appendingPathComponent("expanded-gcm")
    try journal.run(
      "gcm-package-expand",
      NativeCommand(.packages, arguments: ["--expand-full", package.path, expanded.path]))
    let components = try FileManager.default.contentsOfDirectory(atPath: expanded.path).filter {
      $0.hasSuffix(".pkg")
    }
    let name = identifier + ".component.pkg"
    guard components == [name] else {
      throw MisoError.invalid("Unexpected credential manager package components")
    }
    let component = try GuestVolume(GuestVolume(expanded).directory(name).url)
    try validateInfo(SafeFile.read(component.path("PackageInfo"), limit: 1 << 20), version: version)
    let bom = try component.path("Bom")
    let log = try journal.run(
      "gcm-package-bom", NativeCommand(.bom, arguments: ["-p", "fmugsl", bom.path]))
    guard let text = String(data: try SafeFile.read(log, limit: 16 << 20), encoding: .utf8) else {
      throw MisoError.invalid("Invalid credential manager BOM encoding")
    }
    var entries = try parseBOM(text)
    let payload = try component.directory("Payload").url
    try PackageInventory.inspect(payload, entries: &entries, cancellation: journal.cancellation)
    let inventory = try BaseInputArchive.inventory(payload, cancellation: journal.cancellation)
    for entry in inventory where entry.path != "." {
      guard let expected = entries[entry.path], entry.mode == expected.mode & 0o777,
        entry.sha256 == expected.sha256
      else {
        throw MisoError.invalid("Credential manager payload differs from BOM")
      }
    }
    try journal.run(
      "gcm-binary-signature",
      NativeCommand(
        .codesign,
        arguments: [
          "--verify", "--strict", payload.appendingPathComponent("git-credential-manager").path,
        ]))
    return Prepared(payload: payload, bom: bom, inventory: inventory)
  }
}

import Darwin
import Foundation

public enum XcodePackages {
  struct Identity: Equatable, Sendable {
    let identifier: String
    let version: String
  }

  struct Policy: Sendable {
    let filename: String
    let identifier: String
    let prefix: String
    let roots: Set<String>
    let linkRoot: String

    static func standard(_ configuration: XcodeConfiguration) throws -> [Policy] {
      try configuration.validate()
      return [
        Policy(
          filename: "CoreTypes.pkg", identifier: "com.apple.pkg.CoreTypes", prefix: "",
          roots: ["System/Library/CoreServices/CoreTypes.bundle/Contents/Library"],
          linkRoot: "System/Library/CoreServices/CoreTypes.bundle/Contents/Library"),
        Policy(
          filename: "MobileDevice.pkg", identifier: "com.apple.pkg.MobileDevice",
          prefix: "Library/Apple", roots: ["System/Library"],
          linkRoot: "System/Library"),
        Policy(
          filename: "MobileDeviceDevelopment.pkg",
          identifier: "com.apple.pkg.MobileDeviceDevelopment",
          prefix: "Library/Apple",
          roots: ["System/Library", "usr"], linkRoot: "System/Library"),
        Policy(
          filename: "XcodeSystemResources.pkg", identifier: "com.apple.pkg.XcodeSystemResources",
          prefix: "", roots: ["Library/Developer"],
          linkRoot: "Library/Developer"),
      ]
    }

    func destination(_ path: String) throws -> String {
      _ = try SafeFile.relativePath(path)
      guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
        throw MisoError.invalid("Xcode payload is outside its writable package roots")
      }
      return prefix.isEmpty ? path : prefix + "/" + path
    }

    @discardableResult
    func validateInfo(_ data: Data) throws -> Identity {
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
      guard parser.parse(), let (name, fields) = delegate.root, name == "pkg-info",
        let actualIdentifier = fields["identifier"], let version = fields["version"],
        version.range(of: #"\A[0-9]+(\.[0-9]+)*\z"#, options: .regularExpression) != nil,
        fields["useHFSPlusCompression"] == "true", fields["auth"] == "root",
        fields["system-volume-group-install-location"]
          == (prefix.isEmpty ? nil : "/" + prefix + "/"),
        fields["install-location"] == nil
      else { throw MisoError.invalid("Unreviewed Xcode package metadata: \(filename)") }
      let coreTypesVariant =
        filename == "CoreTypes.pkg"
        && actualIdentifier.range(
          of: #"\Acom\.apple\.pkg\.CoreTypes\.[A-Za-z0-9]+\z"#, options: .regularExpression) != nil
      guard actualIdentifier == identifier || coreTypesVariant else {
        throw MisoError.invalid("Unexpected Xcode package identifier: \(actualIdentifier)")
      }
      return Identity(identifier: actualIdentifier, version: version)
    }

    func identity(in application: URL, journal: ExecutionJournal) throws -> Identity {
      let package = try GuestVolume(application).path("Contents/Resources/Packages/" + filename)
      let info = try journal.run(
        "read-package-info-" + filename.lowercased().replacingOccurrences(of: ".", with: "-"),
        NativeCommand(.tar, arguments: ["-xOf", package.path, "PackageInfo"]))
      return try validateInfo(SafeFile.read(info, limit: 2 << 20))
    }
  }

  public struct Package: Codable, Sendable {
    public let filename: String
    public let identifier: String
    public let version: String
    public let prefix: String
    public let archive: ImageBundle.FileRecord
    public let info: ImageBundle.FileRecord
    public let bom: ImageBundle.FileRecord
    public let inventory: ImageBundle.FileRecord
    public let scriptsNotExecuted: [ImageBundle.FileRecord]
  }

  public struct Receipt: Codable, Sendable {
    public let schemaVersion: Int
    public let target: MacOSRelease
    public let configuration: XcodeConfiguration
    public let packages: [Package]
    public let vmStarted: Bool
    public let hostInstalled: Bool
    public let xcodeImageComplete: Bool
  }

  public static func prepare(
    preparedArchive: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    let source = try GuestVolume(preparedArchive)
    let archive = try JSON.read(XcodeArchive.Receipt.self, from: source.path("archive.json"))
    guard archive.schemaVersion == 1, archive.payload == "expanded/Xcode.app", !archive.vmStarted,
      !archive.runtimeVerified, !archive.xcodeImageComplete
    else { throw MisoError.invalid("Unexpected Xcode archive preparation") }
    let policies = try Policy.standard(archive.configuration)
    let app = try source.directory(archive.payload).url
    try AppleCode.validate(app)
    guard
      try XcodeArchive.inspect(app, target: archive.target, configuration: archive.configuration)
        == archive.application
    else { throw MisoError.invalid("Xcode application metadata differs from preparation") }
    let packages = try GuestVolume(app).directory("Contents/Resources/Packages").url
    guard
      Set(try FileManager.default.contentsOfDirectory(atPath: packages.path))
        == Set(policies.map(\.filename))
    else { throw MisoError.invalid("Unreviewed Xcode first-launch package set") }
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-packages", cancellation: cancellation)
    return try journal.perform {
      try journal.setMetadata("target", value: archive.target)
      try journal.setMetadata("configuration", value: archive.configuration)
      var records: [Package] = []
      for (index, policy) in policies.enumerated() {
        let package = packages.appendingPathComponent(policy.filename)
        let original = try Artifacts.record(package, relativeTo: packages)
        let copy = output.appendingPathComponent(policy.filename)
        try Artifacts.copy(
          package, to: copy, maximumBytes: original.bytes, cancellation: journal.cancellation)
        let copied = try Artifacts.record(copy, relativeTo: output)
        guard copied == original else {
          throw MisoError.invalid("Xcode package changed while copying")
        }
        let signature = try journal.run(
          "package-signature-\(index)",
          NativeCommand(.packages, arguments: ["--check-signature", copy.path]))
        guard
          String(decoding: try SafeFile.read(signature, limit: 1 << 20), as: UTF8.self).contains(
            "Status: signed Apple Software")
        else { throw MisoError.invalid("Xcode package is not signed Apple software") }
        let expanded = output.appendingPathComponent(policy.filename + ".expanded")
        try journal.run(
          "package-expand-\(index)",
          NativeCommand(
            .packages, arguments: ["--expand-full", copy.path, expanded.path], timeout: 900))
        let tree = try GuestVolume(expanded)
        let info = try tree.path("PackageInfo")
        let identity = try policy.validateInfo(SafeFile.read(info, limit: 2 << 20))
        let bom = try tree.path("Bom")
        let listing = try journal.run(
          "package-bom-\(index)", NativeCommand(.bom, arguments: ["-p", "fmugsl", bom.path]))
        guard let text = String(data: try SafeFile.read(listing, limit: 32 << 20), encoding: .utf8)
        else { throw MisoError.invalid("Invalid Xcode package BOM encoding") }
        var entries = try PackageInventory.parse(
          text, roots: policy.roots, linkRoot: policy.linkRoot)
        try PackageInventory.inspect(
          tree.path("Payload"), entries: &entries, cancellation: journal.cancellation)
        let inventory = output.appendingPathComponent(policy.filename + ".inventory.json")
        try SafeFile.writeNew(JSON.encode(entries), to: inventory)
        var scripts: [ImageBundle.FileRecord] = []
        if try tree.contains("Scripts") {
          let scriptsRoot = try tree.directory("Scripts").url
          try FileMetadata.walk(scriptsRoot) { path, info in
            try journal.cancellation.check()
            guard [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT) else {
              throw MisoError.invalid("Unsupported Xcode package script entry")
            }
            if info.st_mode & S_IFMT == S_IFREG {
              scripts.append(
                try Artifacts.record(scriptsRoot.appendingPathComponent(path), relativeTo: output))
            }
          }
        }
        guard try Artifacts.record(package, relativeTo: packages) == original else {
          throw MisoError.invalid("Source Xcode package changed")
        }
        records.append(
          Package(
            filename: policy.filename, identifier: identity.identifier, version: identity.version,
            prefix: policy.prefix,
            archive: copied, info: try Artifacts.record(info, relativeTo: output),
            bom: try Artifacts.record(bom, relativeTo: output),
            inventory: try Artifacts.record(inventory, relativeTo: output),
            scriptsNotExecuted: scripts.sorted { $0.path < $1.path }))
      }
      let receipt = Receipt(
        schemaVersion: 1, target: archive.target, configuration: archive.configuration,
        packages: records,
        vmStarted: false, hostInstalled: false, xcodeImageComplete: false)
      try SafeFile.writeNew(
        JSON.encode(receipt), to: output.appendingPathComponent("packages.json"))
      return receipt
    }
  }
}

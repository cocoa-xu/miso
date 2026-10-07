import CryptoKit
import Darwin
import Foundation

public enum XcodeAndroidInputs {
  struct Package: Codable, Equatable {
    let identifier: String
    let revision: String
    let filename: String
    let bytes: UInt64
    let sha1: String
    let license: String

    var url: URL { URL(string: "https://dl.google.com/android/repository/" + filename)! }
    var directory: String { identifier.replacingOccurrences(of: ";", with: "-") }
  }

  struct Selection: Codable, Equatable {
    let packages: [Package]
    let licenses: [String: String]
  }

  struct Item: Codable {
    let package: Package
    let archive: ImageBundle.FileRecord
    let inventory: ImageBundle.FileRecord
    let root: String
    let properties: [String: String]
    let minimumMacOS: [String: String]
  }

  public struct Receipt: Codable {
    let target: MacOSRelease
    let metadata: ImageBundle.FileRecord
    let selection: Selection
    let items: [Item]
    let licenseCatalogs: [ImageBundle.FileRecord]?
    let vmStarted: Bool
    let installationVerified: Bool
  }

  static let identifiers = [
    "cmdline-tools;20.0", "platform-tools", "platforms;android-36", "build-tools;36.0.0",
    "ndk;28.2.13676358",
  ]

  static func parse(_ data: Data) throws -> Selection {
    guard data.count <= 8 << 20, let text = String(data: data, encoding: .utf8),
      !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY")
    else { throw MisoError.invalid("Invalid Android repository XML") }
    let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    guard let root = document.rootElement(), root.localName == "sdk-repository",
      root.uri == "http://schemas.android.com/sdk/android/repo/repository2/03"
    else {
      throw MisoError.invalid("Unexpected Android repository root")
    }
    func one(_ element: XMLElement, _ name: String) throws -> XMLElement {
      let values = element.elements(forName: name)
      guard values.count == 1 else {
        throw MisoError.invalid("Missing or ambiguous Android field: \(name)")
      }
      return values[0]
    }
    func value(_ element: XMLElement, _ name: String) throws -> String {
      guard let text = try one(element, name).stringValue else {
        throw MisoError.invalid("Empty Android field")
      }
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var packages: [Package] = []
    var licenses: [String: String] = [:]
    for identifier in identifiers {
      let matches = root.elements(forName: "remotePackage").filter {
        $0.attribute(forName: "path")?.stringValue == identifier
      }
      guard matches.count == 1, let package = matches.first,
        package.attribute(forName: "obsolete")?.stringValue != "true",
        package.elements(forName: "dependencies").isEmpty,
        try one(package, "channelRef").attribute(forName: "ref")?.stringValue == "channel-0"
      else {
        throw MisoError.unsupported("Android package or prerequisites changed: \(identifier)")
      }
      let revision = try one(package, "revision")
      guard revision.elements(forName: "preview").isEmpty else {
        throw MisoError.invalid("Android preview packages are not supported")
      }
      let parts = try ["major", "minor", "micro"].compactMap { name -> String? in
        let values = revision.elements(forName: name)
        guard !values.isEmpty || name == "major" else { return nil }
        let text = try value(revision, name)
        guard let number = UInt32(text), String(number) == text else {
          throw MisoError.invalid("Invalid Android package revision")
        }
        return text
      }
      let version = parts.joined(separator: ".")
      _ = try StableVersion(version)
      if let expected = identifier.split(separator: ";").last,
        identifier.hasPrefix("cmdline-tools;") || identifier.hasPrefix("build-tools;")
          || identifier.hasPrefix("ndk;")
      {
        guard try StableVersion(version) == StableVersion(String(expected)) else {
          throw MisoError.invalid("Android package path and revision differ")
        }
      }
      if identifier == "platforms;android-36" {
        guard try value(one(package, "type-details"), "api-level") == "36" else {
          throw MisoError.invalid("Android platform API differs from configuration")
        }
      }
      let archives = try one(package, "archives").elements(forName: "archive").filter { archive in
        let os = archive.elements(forName: "host-os").first?.stringValue
        let arch = archive.elements(forName: "host-arch").first?.stringValue
        return (os == nil || os == "macosx")
          && (arch == nil || arch == "arm64" || arch == "aarch64")
      }
      guard archives.count == 1 else { throw MisoError.invalid("Ambiguous Android macOS archive") }
      let complete = try one(archives[0], "complete")
      let filename = try value(complete, "url")
      let hash = try value(complete, "checksum")
      guard
        filename.range(of: #"\A[A-Za-z0-9][A-Za-z0-9_.-]+\.zip\z"#, options: .regularExpression)
          != nil,
        let bytes = try UInt64(value(complete, "size")), (1...(2 << 30)).contains(bytes),
        try one(complete, "checksum").attribute(forName: "type")?.stringValue == "sha1",
        hash.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil,
        let license = try one(package, "uses-license").attribute(forName: "ref")?.stringValue,
        license == "android-sdk-license"
      else { throw MisoError.invalid("Invalid Android archive identity or license") }
      if identifier == "cmdline-tools;20.0", filename != "commandlinetools-mac-14742923_latest.zip"
      {
        throw MisoError.invalid("Android command-line tools differ from the configured archive")
      }
      let matchingLicenses = root.elements(forName: "license").filter {
        $0.attribute(forName: "id")?.stringValue == license
      }
      guard matchingLicenses.count == 1, let terms = matchingLicenses[0].stringValue,
        !terms.isEmpty, terms.utf8.count <= 1 << 20
      else { throw MisoError.invalid("Missing or ambiguous Android license") }
      licenses[license] = terms
      packages.append(
        Package(
          identifier: identifier, revision: version, filename: filename, bytes: bytes, sha1: hash,
          license: license))
    }
    return Selection(packages: packages, licenses: licenses)
  }

  static func sha1(_ url: URL, cancellation: CancellationToken?) throws -> String {
    let file = try SafeFile.openRegular(url)
    defer { try? file.close() }
    var digest = Insecure.SHA1()
    var remaining = try SafeFile.size(file)
    while remaining > 0 {
      try cancellation?.check()
      let count = Int(min(remaining, 1 << 20))
      digest.update(data: try file.readExactly(count))
      remaining -= UInt64(count)
    }
    return SafeFile.hex(digest.finalize())
  }

  static func properties(_ data: Data) throws -> [String: String] {
    guard data.count <= 1 << 20, let text = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid Android source.properties")
    }
    var result: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw MisoError.invalid("Malformed Android property") }
      let key = parts[0].trimmingCharacters(in: .whitespaces)
      let value = parts[1].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, result.updateValue(value, forKey: key) == nil else {
        throw MisoError.invalid("Duplicate Android property")
      }
    }
    return result
  }

  public static func prepare(
    target: MacOSRelease, output: URL, cache: URL? = nil,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try RestoreProfile.select(target)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-xcode-android", cancellation: cancellation)
    do {
      let previous = try cache.map {
        try JSON.read(Receipt.self, from: GuestVolume($0).path("android.json"))
      }
      let data: Data
      if let previous, let cache {
        guard previous.target == target else {
          throw MisoError.invalid("Android cache target differs")
        }
        data = try SafeFile.read(Artifacts.resolve(previous.metadata, under: cache), limit: 8 << 20)
      } else {
        data = try await HTTPData.get(
          URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!,
          maximumBytes: 8 << 20, cancellation: journal.cancellation)
      }
      let selection = try parse(data)
      if let previous, previous.selection != selection {
        throw MisoError.invalid("Android cache selection differs")
      }
      let metadata = output.appendingPathComponent("repository.xml")
      try SafeFile.writeNew(data, to: metadata)
      let licenseCatalogs = try await XcodeAndroidLicenses.prepare(
        output: output, previous: previous?.licenseCatalogs, cache: cache,
        cancellation: journal.cancellation)
      var items: [Item] = []
      for package in selection.packages {
        let directory = output.appendingPathComponent(package.directory)
        try SafeFile.makeDirectory(directory)
        let archive = directory.appendingPathComponent(package.filename)
        if let previous, let cache {
          let matches = previous.items.filter { $0.package == package }
          guard matches.count == 1 else {
            throw MisoError.invalid("Android cache package missing or duplicated")
          }
          try Artifacts.copy(
            Artifacts.resolve(matches[0].archive, under: cache), to: archive,
            maximumBytes: package.bytes, cancellation: journal.cancellation)
        } else {
          try await HTTPFile.get(
            package.url, to: archive, maximumBytes: package.bytes,
            cancellation: journal.cancellation)
        }
        let record = try Artifacts.record(archive, relativeTo: output)
        guard record.bytes == package.bytes,
          try sha1(archive, cancellation: journal.cancellation) == package.sha1
        else {
          throw MisoError.invalid("Android archive checksum or size differs")
        }
        let expanded = directory.appendingPathComponent("expanded")
        try ZIPPayload.extract(archive, to: expanded, cancellation: journal.cancellation)
        let names = try FileManager.default.contentsOfDirectory(atPath: expanded.path)
        guard names.count == 1 else {
          throw MisoError.invalid("Android archive has multiple roots")
        }
        let root = try GuestVolume(GuestVolume(expanded).directory(names[0]).url)
        let fields = try properties(SafeFile.read(root.path("source.properties"), limit: 1 << 20))
        guard let version = fields["Pkg.Revision"],
          try StableVersion(version) == StableVersion(package.revision)
        else {
          throw MisoError.invalid("Android payload revision differs from repository")
        }
        let probes: [String]
        switch package.identifier {
        case "platform-tools": probes = ["adb", "fastboot"]
        case "build-tools;36.0.0": probes = ["aapt2", "zipalign"]
        case "ndk;28.2.13676358": probes = ["toolchains/llvm/prebuilt/darwin-x86_64/bin/clang"]
        default: probes = []
        }
        var minimums: [String: String] = [:]
        for path in probes {
          let file = try root.path(path, allowLeafLink: true)
          let resolved = file.resolvingSymlinksInPath()
          guard resolved.path.hasPrefix(root.root.path + "/") else {
            throw MisoError.invalid("Android executable escapes its package")
          }
          let minimum = try TapFormula.minimumMacOS(SafeFile.read(resolved, limit: 512 << 20))
          guard minimum <= (try MacOSVersion(target.version)) else {
            throw MisoError.unsupported("Android tool requires a newer macOS")
          }
          try journal.run(
            "verify-android-signature",
            NativeCommand(
              .codesign, arguments: ["--verify", "--strict", resolved.path], timeout: 90))
          minimums[path] = minimum.description
        }
        let inventory = directory.appendingPathComponent("inventory.json")
        try SafeFile.writeNew(
          JSON.encode(BaseInputArchive.inventory(root.root, cancellation: journal.cancellation)),
          to: inventory)
        items.append(
          Item(
            package: package, archive: record,
            inventory: try Artifacts.record(inventory, relativeTo: output),
            root: package.directory + "/expanded/" + names[0], properties: fields,
            minimumMacOS: minimums))
      }
      let result = Receipt(
        target: target, metadata: try Artifacts.record(metadata, relativeTo: output),
        selection: selection, items: items, licenseCatalogs: licenseCatalogs,
        vmStarted: false, installationVerified: false)
      try SafeFile.writeNew(JSON.encode(result), to: output.appendingPathComponent("android.json"))
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }
}

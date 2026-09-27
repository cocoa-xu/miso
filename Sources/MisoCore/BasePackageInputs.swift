import CryptoKit
import Foundation

public enum BasePackageInputs {
  public struct Runtimes: Codable, Equatable {
    public let node: String
    public let npm: String
    public let rubygems: String

    public init(node: String, npm: String, rubygems: String) {
      self.node = node
      self.npm = npm
      self.rubygems = rubygems
    }

    func validate() throws {
      for version in [node, npm, rubygems] { _ = try StableVersion(version) }
    }
  }

  public struct Package: Codable {
    let name: String
    let version: String
    let metadata: ImageBundle.FileRecord
    let payload: ImageBundle.FileRecord
  }

  public struct Plan: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let rubyVersion: String
    let nodeFormula: String
    let bundler: Package
    let npm: [Package]
    var runtimes: Runtimes? = nil

    func validate() throws {
      _ = try RestoreProfile.select(target)
      _ = try StableVersion(rubyVersion)
      try runtimes?.validate()
      guard schemaVersion == 1, bundler.name == "bundler", (1...64).contains(npm.count),
        Set(npm.map(\.name)).count == npm.count,
        nodeFormula.range(of: #"\Anode(@[0-9]+)?\z"#, options: .regularExpression) != nil
      else { throw MisoError.invalid("Invalid Base package plan") }
      for package in [bundler] + npm {
        _ = try StableVersion(package.version)
        guard
          package.name.range(
            of: #"\A(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*\z"#,
            options: .regularExpression) != nil,
          package.metadata.bytes > 0, package.metadata.bytes <= 8 << 20,
          package.payload.bytes > 0, package.payload.bytes <= 512 << 20
        else { throw MisoError.invalid("Invalid Base package identity") }
        for record in [package.metadata, package.payload] {
          _ = try SafeFile.relativePath(record.path)
          try SafeFile.validateSHA256(record.sha256)
        }
      }
    }
  }

  struct NPMMetadata: Decodable {
    struct Distribution: Decodable { let integrity: String }
    let name: String
    let version: String
    let dist: Distribution
    let os: [String]?
    let cpu: [String]?

    func requireTarget() throws {
      for (values, target) in [(os, "darwin"), (cpu, "arm64")] {
        guard let values else { continue }
        guard !values.contains("!" + target),
          values.allSatisfy({ $0.hasPrefix("!") }) || values.contains(target)
            || values.contains("any")
        else { throw MisoError.invalid("npm package does not support the target platform") }
      }
    }
  }

  struct GemMetadata: Decodable {
    struct Dependencies: Decodable { let runtime: [JSONValue] }
    let name: String
    let version: String
    let sha: String
    let dependencies: Dependencies
  }

  public static func verify(
    plan planURL: URL, inputs: URL, cancellation: CancellationToken? = nil
  ) throws -> Plan {
    let plan = try JSON.read(Plan.self, from: planURL)
    try plan.validate()
    for package in [plan.bundler] + plan.npm {
      let metadata = try Artifacts.resolve(
        package.metadata, under: inputs, cancellation: cancellation)
      let payload = try Artifacts.resolve(
        package.payload, under: inputs, cancellation: cancellation)
      if package.name == "bundler" {
        let gem = try JSON.read(GemMetadata.self, from: metadata)
        guard gem.name == package.name, gem.version == package.version,
          gem.sha == package.payload.sha256, gem.dependencies.runtime.isEmpty
        else { throw MisoError.invalid("Bundler metadata or dependencies differ from plan") }
      } else {
        let npm = try JSON.read(NPMMetadata.self, from: metadata)
        try npm.requireTarget()
        guard npm.name == package.name, npm.version == package.version,
          try integrity(payload, cancellation: cancellation) == npm.dist.integrity
        else { throw MisoError.invalid("npm payload differs from registry metadata") }
        let entries = try TarPayload.inspect(payload, cancellation: cancellation)
        guard entries.allSatisfy({ $0.path == "package" || $0.path.hasPrefix("package/") }),
          entries.contains(where: { $0.path == "package/package.json" && $0.link == nil })
        else { throw MisoError.invalid("Unexpected npm archive layout") }
      }
    }
    return plan
  }

  static func integrity(_ file: URL, cancellation: CancellationToken? = nil) throws -> String {
    let handle = try SafeFile.openRegular(file)
    defer { try? handle.close() }
    let size = try SafeFile.size(handle)
    var consumed: UInt64 = 0
    var digest = SHA512()
    while consumed < size {
      try autoreleasepool {
        try cancellation?.check()
        let chunk = try handle.readExactly(Int(min(8 << 20, size - consumed)))
        digest.update(data: chunk)
        consumed += UInt64(chunk.count)
      }
    }
    guard try (handle.read(upToCount: 1) ?? Data()).isEmpty, try SafeFile.size(handle) == size
    else {
      throw MisoError.invalid("npm payload changed while hashing")
    }
    return "sha512-" + Data(digest.finalize()).base64EncodedString()
  }
}

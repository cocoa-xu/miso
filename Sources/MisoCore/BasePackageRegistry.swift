import Foundation

struct BasePackageRegistry {
  enum CompatibilityError: Error { case minimumMacOS }

  let output: URL
  let cache: GuestVolume?
  let cancellation: CancellationToken
  private var documents: [String: Data] = [:]

  init(output: URL, cache: GuestVolume?, cancellation: CancellationToken) {
    self.output = output
    self.cache = cache
    self.cancellation = cancellation
  }

  mutating func document(_ key: String, url: URL, compact: Bool = false) async throws -> Data {
    if let data = documents[key] { return data }
    let relative = "metadata/" + key + ".json"
    let data: Data
    if let cache {
      data = try SafeFile.read(cache.path(relative), limit: 8 << 20)
    } else {
      data = try await HTTPData.get(
        url, maximumBytes: 8 << 20, cancellation: cancellation,
        accept: compact ? "application/vnd.npm.install-v1+json" : "application/json")
    }
    try SafeFile.writeNew(data, to: output.appendingPathComponent(relative))
    documents[key] = data
    return data
  }

  func payload(_ relative: String, url: URL) async throws -> URL {
    let destination = output.appendingPathComponent(relative)
    if let cache {
      try Artifacts.copy(
        cache.path(relative), to: destination, maximumBytes: 512 << 20,
        cancellation: cancellation)
    } else {
      try await HTTPFile.get(
        url, to: destination, maximumBytes: 512 << 20, cancellation: cancellation)
    }
    return destination
  }

  mutating func npmDocument(_ name: String) async throws -> Data {
    let escaped = name.replacingOccurrences(of: "/", with: "%2f")
    return try await document(
      "npm-" + name.replacingOccurrences(of: "/", with: "_"),
      url: URL(string: "https://registry.npmjs.org/" + escaped)!, compact: true)
  }

  func npmPayload(_ value: PackageRegistryMetadata.NPM, bytes: Data, target: MacOSRelease)
    async throws
    -> BasePackageInputs.Package
  {
    try value.validate()
    let key = value.name.replacingOccurrences(of: "/", with: "_") + "-" + value.version
    let metadata = output.appendingPathComponent("metadata/" + key + ".json")
    try SafeFile.writeNew(bytes, to: metadata)
    let archive = try await payload("payloads/" + key + ".tgz", url: value.dist.tarball)
    guard
      try BasePackageInputs.integrity(archive, cancellation: cancellation) == value.dist.integrity
    else { throw MisoError.invalid("npm payload checksum differs from registry: \(value.name)") }
    let entries = try TarPayload.inspect(archive, cancellation: cancellation)
    guard entries.allSatisfy({ $0.path == "package" || $0.path.hasPrefix("package/") }) else {
      throw MisoError.invalid("Unexpected npm package archive layout")
    }
    try value.validateManifest(
      TarPayload.file(
        archive, path: "package/package.json", maximumBytes: 1 << 20, cancellation: cancellation))
    if value.name == PackageRegistryMetadata.nativePNPM {
      let binaries = entries.filter {
        ($0.path as NSString).lastPathComponent == "pnpm" && $0.link == nil
      }
      guard binaries.count == 1 else { throw MisoError.invalid("Unexpected native pnpm archive") }
      let executable = try TarPayload.file(
        archive, path: binaries[0].path, maximumBytes: 256 << 20, cancellation: cancellation)
      guard try BasePackageResolution.minimumMacOS(executable) <= MacOSVersion(target.version)
      else {
        throw CompatibilityError.minimumMacOS
      }
    }
    return BasePackageInputs.Package(
      name: value.name, version: value.version,
      metadata: try Artifacts.record(metadata, relativeTo: output),
      payload: try Artifacts.record(archive, relativeTo: output))
  }

  func records(_ directory: String) throws -> [ImageBundle.FileRecord] {
    try FileManager.default.contentsOfDirectory(
      atPath: output.appendingPathComponent(directory).path
    ).sorted().map {
      try Artifacts.record(output.appendingPathComponent(directory + "/" + $0), relativeTo: output)
    }
  }
}

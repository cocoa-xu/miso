import Foundation

struct OCIReference: Sendable {
  let repository: String
  let version: String

  init(_ value: String) throws {
    guard value.hasPrefix("ghcr.io/") else {
      throw MisoError.invalid("Expected a ghcr.io repository with a tag or digest")
    }
    let name = String(value.dropFirst(8))
    if let separator = name.firstIndex(of: "@") {
      repository = String(name[..<separator])
      version = String(name[name.index(after: separator)...])
      try OCIDescriptor.validateDigest(version)
    } else if let separator = name.lastIndex(of: ":") {
      repository = String(name[..<separator])
      version = String(name[name.index(after: separator)...])
      guard
        version.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z"#, options: .regularExpression)
          != nil
      else { throw MisoError.invalid("Invalid OCI tag") }
    } else {
      throw MisoError.invalid("Specify an OCI tag or digest")
    }
    guard repository.utf8.count <= 255,
      repository.range(
        of: #"\A[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+\z"#,
        options: .regularExpression) != nil
    else { throw MisoError.invalid("Invalid OCI repository") }
  }

  var name: String { "ghcr.io/" + repository }
  func url(_ suffix: String) -> URL { URL(string: "https://ghcr.io/v2/\(repository)/\(suffix)")! }
}

struct OCIDescriptor: Codable, Equatable, Sendable {
  let mediaType: String
  let size: UInt64
  let digest: String
  var annotations: [String: String]? = nil

  static func validateDigest(_ digest: String) throws {
    guard digest.hasPrefix("sha256:") else { throw MisoError.invalid("Unsupported OCI digest") }
    try SafeFile.validateSHA256(String(digest.dropFirst(7)))
  }

  func validate(maximumSize: UInt64) throws {
    try Self.validateDigest(digest)
    guard size > 0, size <= maximumSize else { throw MisoError.invalid("Invalid OCI blob size") }
  }

  func file(in directory: URL) -> URL {
    directory.appendingPathComponent(String(digest.dropFirst(7)))
  }
}

struct OCIManifest: Codable, Sendable {
  static let manifestType = "application/vnd.oci.image.manifest.v1+json"
  static let imageConfigType = "application/vnd.oci.image.config.v1+json"
  static let configType = "application/vnd.cirruslabs.tart.config.v1"
  static let diskType = "application/vnd.cirruslabs.tart.disk.v2"
  static let nvramType = "application/vnd.cirruslabs.tart.nvram.v1"
  static let layerBytes: UInt64 = 512 << 20
  let schemaVersion: Int
  let mediaType: String
  let config: OCIDescriptor
  let layers: [OCIDescriptor]
  let annotations: [String: String]

  var blobs: [OCIDescriptor] {
    var seen = Set<String>()
    return ([config] + layers).filter { seen.insert($0.digest).inserted }
  }

  func validate() throws -> UInt64 {
    guard schemaVersion == 2, mediaType == Self.manifestType,
      config.mediaType == Self.imageConfigType, (3...4098).contains(layers.count),
      layers.first?.mediaType == Self.configType, layers.last?.mediaType == Self.nvramType
    else { throw MisoError.invalid("Expected a flat Tart-compatible OCI image") }
    try config.validate(maximumSize: 1 << 20)
    try layers[0].validate(maximumSize: 1 << 20)
    try layers[layers.count - 1].validate(maximumSize: 64 << 20)
    var size: UInt64 = 0
    var known: [String: OCIDescriptor] = [:]
    for blob in [config] + layers {
      if let existing = known[blob.digest] {
        guard existing.mediaType == blob.mediaType, existing.size == blob.size,
          [
            "org.cirruslabs.tart.uncompressed-size",
            "org.cirruslabs.tart.uncompressed-content-digest",
          ]
          .allSatisfy({ existing.annotations?[$0] == blob.annotations?[$0] })
        else { throw MisoError.invalid("Conflicting OCI descriptors for the same blob") }
      }
      known[blob.digest] = blob
    }
    for layer in layers.dropFirst().dropLast() {
      try layer.validate(maximumSize: Self.layerBytes + (8 << 20))
      guard layer.mediaType == Self.diskType,
        let count = layer.annotations?["org.cirruslabs.tart.uncompressed-size"].flatMap(
          UInt64.init),
        count > 0, count <= Self.layerBytes,
        let digest = layer.annotations?["org.cirruslabs.tart.uncompressed-content-digest"]
      else { throw MisoError.invalid("Invalid OCI disk layer") }
      try OCIDescriptor.validateDigest(digest)
      size += count
    }
    guard annotations["org.cirruslabs.tart.uncompressed-disk-size"] == String(size) else {
      throw MisoError.invalid("OCI disk size differs from its layers")
    }
    return size
  }
}

enum OCIPack {
  static func run(
    source: URL, blobs: URL, labels: [String: String], cancellation: CancellationToken
  ) throws -> OCIManifest {
    let names = ["config.json", "disk.img", "nvram.bin"]
    let before = try names.map { try FileMetadata.inspect(source.appendingPathComponent($0)) }
    let config = try SafeFile.read(source.appendingPathComponent("config.json"), limit: 1 << 20)
    try validateConfiguration(config)
    let nvram = try SafeFile.read(source.appendingPathComponent("nvram.bin"), limit: 64 << 20)
    try SafeFile.makeDirectory(blobs)
    func store(_ bytes: Data, type: String) throws -> OCIDescriptor {
      let descriptor = OCIDescriptor(
        mediaType: type, size: UInt64(bytes.count), digest: "sha256:" + SafeFile.sha256(bytes))
      if !FileManager.default.fileExists(atPath: descriptor.file(in: blobs).path) {
        try SafeFile.writeNew(bytes, to: descriptor.file(in: blobs))
      }
      return descriptor
    }
    var labels = labels
    labels["org.cirruslabs.tart.disk.format"] = "raw"
    let configuration = try JSONSerialization.data(
      withJSONObject: ["architecture": "arm64", "os": "darwin", "config": ["Labels": labels]],
      options: [.sortedKeys])
    let imageConfig = try store(configuration, type: OCIManifest.imageConfigType)
    var layers = [try store(config, type: OCIManifest.configType)]
    let disk = try SafeFile.openRegular(source.appendingPathComponent("disk.img"))
    defer { try? disk.close() }
    let size = try SafeFile.size(disk)
    guard size > 0, size <= OCIManifest.layerBytes * 4096 else {
      throw MisoError.invalid("Unsupported OCI disk size")
    }
    var offset: UInt64 = 0
    while offset < size {
      try cancellation.check()
      try Artifacts.requireSpace(OCIManifest.layerBytes + (8 << 20), at: blobs)
      let count = min(OCIManifest.layerBytes, size - offset)
      let temporary = blobs.appendingPathComponent("layer-\(layers.count)")
      let output = try SafeFile.create(temporary)
      let result: OCICompression.Result
      do {
        result = try OCICompression.process(
          input: disk, bytes: count, encoding: true,
          maximumOutput: count + (8 << 20), cancellation: cancellation
        ) { try output.write(contentsOf: $0) }
        try output.close()
      } catch {
        try? output.close()
        throw error
      }
      let descriptor = OCIDescriptor(
        mediaType: OCIManifest.diskType, size: result.outputBytes, digest: result.outputDigest,
        annotations: [
          "org.cirruslabs.tart.uncompressed-size": String(count),
          "org.cirruslabs.tart.uncompressed-content-digest": result.inputDigest,
        ])
      if FileManager.default.fileExists(atPath: descriptor.file(in: blobs).path) {
        try FileManager.default.removeItem(at: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: descriptor.file(in: blobs))
      }
      layers.append(descriptor)
      offset += count
      BuildProgress.write(
        "Compress image: \(TransferProgress.size(Double(offset))) / \(TransferProgress.size(Double(size)))"
      )
    }
    layers.append(try store(nvram, type: OCIManifest.nvramType))
    for (index, name) in names.enumerated() {
      let after = try FileMetadata.inspect(source.appendingPathComponent(name))
      let original = before[index]
      guard after.st_ino == original.st_ino, after.st_dev == original.st_dev,
        after.st_size == original.st_size,
        after.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
        after.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
        after.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
        after.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
      else { throw MisoError.invalid("OCI source changed during compression") }
    }
    return OCIManifest(
      schemaVersion: 2, mediaType: OCIManifest.manifestType, config: imageConfig,
      layers: layers,
      annotations: [
        "org.cirruslabs.tart.uncompressed-disk-size": String(size),
        "org.cirruslabs.tart.upload-time": ISO8601DateFormatter().string(from: Date()),
      ])
  }

  static func validateConfiguration(_ data: Data) throws {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      value["version"] as? Int == 1, value["os"] as? String == "darwin",
      value["arch"] as? String == "arm64", (value["diskFormat"] as? String ?? "raw") == "raw"
    else { throw MisoError.invalid("Expected an Apple silicon raw macOS image") }
  }
}

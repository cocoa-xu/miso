import Foundation

enum XcodeDownload {
  private struct Release: Decodable {
    struct Version: Decodable {
      struct Channel: Decodable { let release: Bool? }
      let number: String
      let build: String
      let release: Channel
    }
    struct Links: Decodable {
      struct Download: Decodable {
        let url: URL
        let architectures: [String]?
      }
      let download: Download?
    }
    let version: Version
    let links: Links?
  }

  static func filename(catalog: Data, configuration: XcodeConfiguration) throws -> String {
    try configuration.validate()
    let version = try StableVersion(configuration.version)
    let releases = try JSONDecoder().decode([Release].self, from: catalog).filter {
      $0.version.build == configuration.build
        && (try? StableVersion($0.version.number)) == version
        && ($0.links?.download?.architectures?.contains("arm64") ?? true)
    }
    let stable = releases.filter { $0.version.release.release == true }
    let downloads = (stable.isEmpty ? releases : stable).compactMap { $0.links?.download?.url }
    guard let url = downloads.first, Set(downloads).count == 1,
      url.scheme == "https", url.host == "download.developer.apple.com",
      url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil, url.path.hasPrefix("/Developer_Tools/"),
      url.lastPathComponent.range(
        of: #"\AXcode_[A-Za-z0-9._]+\.xip\z"#, options: .regularExpression) != nil
    else {
      throw MisoError.invalid(
        "No unique Apple archive for Xcode \(configuration.version) (\(configuration.build))")
    }
    return url.lastPathComponent
  }

  static func source(baseURL: String, filename: String) throws -> URL {
    guard baseURL.utf8.count <= 4096,
      baseURL.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
      let url = URL(string: baseURL), url.scheme == "https", url.host != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.port == nil || url.port == 443, !url.path.hasSuffix(".xip"),
      filename.range(of: #"\AXcode_[A-Za-z0-9._]+\.xip\z"#, options: .regularExpression) != nil
    else {
      throw MisoError.invalid(
        "Xcode base URL must be an HTTPS directory without credentials or query")
    }
    return url.appendingPathComponent(filename)
  }

  static func mask(_ value: String) {
    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { return }
    let escaped = value.replacingOccurrences(of: "%", with: "%25")
      .replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
    FileHandle.standardError.write(Data("::add-mask::\(escaped)\n".utf8))
  }

  static func acquire(
    baseURL: String, configuration: XcodeConfiguration, workspace: URL,
    cancellation: CancellationToken? = nil
  ) async throws -> URL {
    _ = try source(baseURL: baseURL, filename: "Xcode_validation.xip")
    mask(baseURL)
    let catalog = try await HTTPData.get(
      URL(string: "https://xcodereleases.com/data.json")!, maximumBytes: 8 << 20,
      cancellation: cancellation)
    let filename = try filename(catalog: catalog, configuration: configuration)
    let source = try source(baseURL: baseURL, filename: filename)
    mask(source.absoluteString)
    let downloads = workspace.appendingPathComponent("downloads")
    try SafeFile.makeDirectory(downloads)
    let archive = downloads.appendingPathComponent(filename)
    BuildProgress.write("Download Xcode archive: \(filename)")
    try await HTTPFile.xcodeArchive(source, to: archive, cancellation: cancellation)
    return archive
  }
}

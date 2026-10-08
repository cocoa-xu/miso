import Darwin
import Foundation

enum XcodeComponentIndex {
  static let url = URL(
    string: "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex"
  )!

  static func metalBuild(_ data: Data, configuration: XcodeConfiguration) throws -> String {
    try configuration.validate()
    guard
      let index = try PropertyListSerialization.propertyList(
        from: data, options: [], format: nil) as? [String: Any],
      let mappings = index["xcodeToOtherDownloadablesMappings"] as? [[String: Any]],
      let assets = index["otherDownloadables"] as? [[String: Any]]
    else { throw MisoError.invalid("Invalid Apple Xcode component index") }
    let matches = mappings.filter {
      $0["assetType"] as? String == "metalToolchain"
        && $0["xcodeBuildUpdate"] as? String == configuration.build
    }
    let preferred = matches.filter { $0["affinity"] as? String == "preferred" }
    let builds = Set(
      (preferred.isEmpty ? matches : preferred).compactMap {
        $0["assetBuildUpdate"] as? String
      })
    guard builds.count == 1, let build = builds.first,
      assets.contains(where: {
        $0["assetType"] as? String == "metalToolchain"
          && $0["assetBuildUpdate"] as? String == build
          && $0["downloadMethod"] as? String == "mobileAsset"
          && $0["contentType"] as? String == "cryptexDiskImage"
      })
    else {
      throw MisoError.unsupported(
        "No unique Metal toolchain in Apple's component index for Xcode \(configuration.build)")
    }
    var assetConfiguration = configuration
    assetConfiguration.build = build
    try assetConfiguration.validate()
    return build
  }

  static func install(
    _ bytes: Data, configuration: XcodeConfiguration, build: String,
    data: GuestVolume, account: BaseImageStage.Account
  ) throws {
    guard try metalBuild(bytes, configuration: configuration) == build else {
      throw MisoError.invalid("Metal component index differs from the installed asset")
    }
    for client in ["com.apple.dt.xcodebuild", "com.apple.dt.Xcode"] {
      let path = "Users/\(account.username)/Library/Caches/" + client
      try data.makeDirectories(path, uid: account.uid, gid: account.gid)
      let directory = try data.directory(path).url
      try FileMetadata.walk(directory) { _, info in
        guard [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else {
          throw MisoError.invalid("Unexpected Xcode URL cache entry")
        }
      }
      try cache(bytes, at: directory)
      try FileMetadata.walk(directory) { relative, info in
        guard [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else {
          throw MisoError.invalid("Unexpected Xcode URL cache entry")
        }
        guard chown(directory.appendingPathComponent(relative).path, account.uid, account.gid) == 0
        else { throw MisoError.system("Set Xcode component index cache ownership", errno) }
      }
    }
  }

  static func cache(_ bytes: Data, at directory: URL) throws {
    let cache = URLCache(memoryCapacity: 0, diskCapacity: 16 << 20, directory: directory)
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": "application/x-plist", "Content-Length": String(bytes.count),
        ])
    else { throw MisoError.invalid("Cannot create the Xcode component index cache response") }
    let request = URLRequest(url: url)
    cache.storeCachedResponse(CachedURLResponse(response: response, data: bytes), for: request)
    guard cache.cachedResponse(for: request)?.data == bytes else {
      throw MisoError.invalid("Cannot cache Apple's Xcode component index")
    }
  }
}

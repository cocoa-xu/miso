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
}

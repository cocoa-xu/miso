import Foundation

enum FlutterPackageConfiguration {
  static let path = "packages/flutter_tools/.dart_tool/package_config.json"

  static func relocate(
    _ bytes: Data, sourceSDK: URL, sourceCache: URL, sdk: URL, cache: URL, version: String
  ) throws -> Data {
    guard var value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      value["configVersion"] as? Int == 2, value["flutterVersion"] as? String == version,
      let flutterRoot = value["flutterRoot"] as? String,
      let pubCache = value["pubCache"] as? String,
      try directory(flutterRoot, relativeTo: sourceSDK).path == sourceSDK.standardizedFileURL.path,
      try directory(pubCache, relativeTo: sourceCache).path == sourceCache.standardizedFileURL.path,
      var packages = value["packages"] as? [[String: Any]], !packages.isEmpty,
      packages.count < 10_000
    else { throw MisoError.invalid("Unexpected Flutter package configuration") }
    let originalParent = sourceSDK.appendingPathComponent(path).deletingLastPathComponent()
    let parent = sdk.appendingPathComponent(path).deletingLastPathComponent()
    var names = Set<String>()
    for index in packages.indices {
      guard let name = packages[index]["name"] as? String, !name.isEmpty,
        names.insert(name).inserted, let root = packages[index]["rootUri"] as? String
      else { throw MisoError.invalid("Invalid Flutter package entry") }
      let original = try directory(root, relativeTo: originalParent)
      let mapped: URL
      if let suffix = suffix(original, under: sourceSDK) {
        _ = try GuestVolume(sourceSDK).directory(suffix.isEmpty ? nil : suffix)
        mapped = sdk.appendingPathComponent(suffix)
      } else if let suffix = suffix(original, under: sourceCache) {
        _ = try GuestVolume(sourceCache).directory(suffix.isEmpty ? nil : suffix)
        mapped = cache.appendingPathComponent(suffix)
      } else {
        throw MisoError.invalid("Flutter package escapes its authenticated SDK and cache")
      }
      packages[index]["rootUri"] = relative(mapped, to: parent)
    }
    value["packages"] = packages
    value["flutterRoot"] = sdk.absoluteString
    value["pubCache"] = cache.absoluteString
    return try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  }

  private static func directory(_ value: String, relativeTo parent: URL) throws -> URL {
    let base = URL(fileURLWithPath: parent.path, isDirectory: true)
    guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
      url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
      !url.path.utf8.contains(0)
    else { throw MisoError.invalid("Invalid Flutter package directory URI") }
    return url.standardizedFileURL
  }

  private static func suffix(_ url: URL, under root: URL) -> String? {
    let base = root.standardizedFileURL.path
    if url.path == base { return "" }
    guard url.path.hasPrefix(base + "/") else { return nil }
    return String(url.path.dropFirst(base.count + 1))
  }

  private static func relative(_ target: URL, to parent: URL) -> String {
    let source = parent.standardizedFileURL.pathComponents
    let destination = target.standardizedFileURL.pathComponents
    let shared = zip(source, destination).prefix { $0 == $1 }.count
    let path =
      Array(repeating: "..", count: source.count - shared)
      + destination.dropFirst(shared)
    var uri = URLComponents()
    uri.path = (path.isEmpty ? "." : path.joined(separator: "/")) + "/"
    return uri.percentEncodedPath
  }
}

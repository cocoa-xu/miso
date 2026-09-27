import Foundation
import Testing

@testable import MisoCore

private struct FlutterConfigurationFixture {
  let temporary: TemporaryDirectory
  var sdk: URL { temporary.url.appendingPathComponent("flutter") }
  var cache: URL { temporary.url.appendingPathComponent("pub-cache") }
  let destination = URL(fileURLWithPath: "/Users/admin/flutter")
  let destinationCache = URL(fileURLWithPath: "/Users/admin/.pub-cache")

  init() throws {
    temporary = try TemporaryDirectory()
    for url in [
      sdk.appendingPathComponent("packages/flutter_tools"),
      cache.appendingPathComponent("hosted/package #1"),
    ] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  func bytes(root: String? = nil) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "configVersion": 2, "flutterVersion": "3.47.6", "flutterRoot": sdk.absoluteString,
      "pubCache": cache.absoluteString, "generator": "pub", "generatorVersion": "3.13.5",
      "packages": [
        [
          "name": "flutter_tools", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.9",
        ],
        [
          "name": "dependency",
          "rootUri": root ?? cache.appendingPathComponent("hosted/package #1").absoluteString,
          "packageUri": "lib/",
        ],
      ],
    ])
  }

  func relocate(_ bytes: Data) throws -> Data {
    try FlutterPackageConfiguration.relocate(
      bytes, sourceSDK: sdk, sourceCache: cache, sdk: destination, cache: destinationCache,
      version: "3.47.6")
  }
}

@Test func flutterConfigurationRelocatesSDKAndCachedPackagesWithoutHostPaths() throws {
  let fixture = try FlutterConfigurationFixture()
  defer { fixture.temporary.remove() }
  let relocated = try fixture.relocate(fixture.bytes())
  let value = try #require(JSONSerialization.jsonObject(with: relocated) as? [String: Any])
  #expect(value["flutterRoot"] as? String == fixture.destination.absoluteString)
  #expect(value["pubCache"] as? String == fixture.destinationCache.absoluteString)
  #expect(!String(decoding: relocated, as: UTF8.self).contains(fixture.temporary.url.path))
  let packages = try #require(value["packages"] as? [[String: String]])
  let base = fixture.destination.appendingPathComponent(
    "packages/flutter_tools/.dart_tool/", isDirectory: true)
  let expected = [
    fixture.destination.appendingPathComponent("packages/flutter_tools"),
    fixture.destinationCache.appendingPathComponent("hosted/package #1"),
  ]
  for (package, directory) in zip(packages, expected) {
    let uri = try #require(package["rootUri"])
    #expect(!uri.hasPrefix("file:"))
    #expect(URL(string: uri, relativeTo: base)?.standardizedFileURL.path == directory.path)
  }
}

@Test func flutterConfigurationRejectsExternalAndMissingPackageRoots() throws {
  let fixture = try FlutterConfigurationFixture()
  defer { fixture.temporary.remove() }
  for root in [
    "file:///etc", "https://example.invalid/package", "file://server/package",
    "../../../../outside", fixture.cache.appendingPathComponent("missing").absoluteString,
  ] {
    #expect(throws: (any Error).self) { try fixture.relocate(fixture.bytes(root: root)) }
  }
}

@Test func flutterConfigurationRejectsDifferentSDKVersionAndCacheIdentity() throws {
  let fixture = try FlutterConfigurationFixture()
  defer { fixture.temporary.remove() }
  var value = try #require(JSONSerialization.jsonObject(with: fixture.bytes()) as? [String: Any])
  value["flutterVersion"] = "3.47.5"
  #expect(throws: MisoError.self) {
    try fixture.relocate(JSONSerialization.data(withJSONObject: value))
  }
  value["flutterVersion"] = "3.47.6"
  value["pubCache"] = "file:///other/cache"
  #expect(throws: MisoError.self) {
    try fixture.relocate(JSONSerialization.data(withJSONObject: value))
  }
}

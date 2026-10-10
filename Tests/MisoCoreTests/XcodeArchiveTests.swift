import Foundation
import Testing

@testable import MisoCore

private let xcodeTarget = MacOSRelease(version: "27.0.1", build: "26A434")

private func xcodeFixture(_ root: URL, minimum: String = "26.6") throws -> URL {
  let app = root.appendingPathComponent("Xcode.app")
  func write(_ path: String, _ values: [String: String]) throws {
    let file = app.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try SafeFile.writeNew(
      PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0),
      to: file)
  }
  try write(
    "Contents/Info.plist",
    [
      "CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "27.0",
      "LSMinimumSystemVersion": minimum,
    ])
  try write(
    "Contents/version.plist",
    [
      "CFBundleShortVersionString": "27.0", "ProductBuildVersion": "27A266a",
    ])
  let platforms = XcodeConfiguration.Platform.allCases.reduce(into: ["MacOSX": "macosx"]) {
    $0.merge($1.sdkNames) { current, _ in current }
  }
  for (platform, name) in platforms {
    try write(
      "Contents/Developer/Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk/SDKSettings.plist",
      ["CanonicalName": name + "27.0", "Version": "27.0"])
  }
  return app
}

@Test func xcodeArchiveAcceptsBetaBundleNamesAndRejectsAmbiguousContents() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let app = try xcodeFixture(directory.url)
  #expect(try XcodeArchive.extractedApplication(in: directory.url).path == app.path)
  let beta = directory.url.appendingPathComponent("Xcode-beta.app")
  try FileManager.default.moveItem(at: app, to: beta)
  #expect(try XcodeArchive.extractedApplication(in: directory.url).path == beta.path)
  try FileManager.default.createSymbolicLink(at: app, withDestinationURL: beta)
  #expect(throws: MisoError.self) { try XcodeArchive.extractedApplication(in: directory.url) }
  try FileManager.default.removeItem(at: beta)
  #expect(throws: (any Error).self) { try XcodeArchive.extractedApplication(in: directory.url) }
}

@Test func xcodeArchiveInspectionRequiresEveryConfiguredSDK() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let app = try xcodeFixture(directory.url)
  let application = try XcodeArchive.inspect(app, target: xcodeTarget, configuration: .init())
  #expect(application.version == "27.0" && application.build == "27A266a")
  #expect(application.sdks.count == 9)
  #expect(application.sdks.allSatisfy { $0.version == "27.0" })
  let watch = app.appendingPathComponent("Contents/Developer/Platforms/WatchSimulator.platform")
  try FileManager.default.removeItem(at: watch)
  #expect(throws: MisoError.self) {
    try XcodeArchive.inspect(app, target: xcodeTarget, configuration: .init())
  }
}

@Test func xcodeArchiveRejectsHostVersionSubstitutionAndIncompatibleTargets() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let app = try xcodeFixture(directory.url)
  var version = XcodeConfiguration()
  version.version = "27.1"
  var build = XcodeConfiguration()
  build.build = "27A9269"
  for configuration in [version, build] {
    #expect(throws: MisoError.self) {
      try XcodeArchive.inspect(app, target: xcodeTarget, configuration: configuration)
    }
  }
  #expect(throws: MisoError.self) {
    try XcodeArchive.inspect(
      app, target: .init(version: "15.6.1", build: "24G90"), configuration: .init())
  }
  var equivalent = XcodeConfiguration()
  equivalent.version = "27"
  #expect(
    try XcodeArchive.inspect(app, target: xcodeTarget, configuration: equivalent).build == "27A266a"
  )
}

@Test func xcodeArchiveRejectsAnSDKOutsideTheSignedApplication() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let app = try xcodeFixture(directory.url)
  let sdk = app.appendingPathComponent(
    "Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
  let outside = directory.url.appendingPathComponent("outside.sdk")
  try FileManager.default.moveItem(at: sdk, to: outside)
  try FileManager.default.createSymbolicLink(at: sdk, withDestinationURL: outside)
  #expect(throws: MisoError.self) {
    try XcodeArchive.inspect(app, target: xcodeTarget, configuration: .init())
  }
}

@Test func xcodeArchiveRejectsUntrustedInputBeforeCreatingOutput() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let archive = directory.url.appendingPathComponent("test.xip")
  let output = directory.url.appendingPathComponent("output")
  try SafeFile.writeNew(Data("untrusted".utf8), to: archive)
  #expect(throws: MisoError.self) {
    try XcodeArchive.prepare(
      archive: archive, sha256: String(repeating: "0", count: 64), target: xcodeTarget,
      output: output)
  }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func xcodeConfigurationRejectsAmbiguousSelection() throws {
  var duplicate = XcodeConfiguration()
  duplicate.platforms.append(.iOS)
  var components = XcodeConfiguration()
  components.components.append(.metalToolchain)
  var version = XcodeConfiguration()
  version.version = "../../Xcode"
  var build = XcodeConfiguration()
  build.build = "latest"
  var architecture = XcodeConfiguration()
  architecture.runtimeArchitecture = "x86_64"
  for configuration in [duplicate, components, version, build, architecture] {
    #expect(throws: MisoError.self) { try configuration.validate() }
  }
}

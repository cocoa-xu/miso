import Foundation
import Testing

@testable import MisoCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["MISO_SDKMANAGER"] != nil))
func liveAndroidLicenseCatalogPreparationAndSDKAcceptance() async throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let fresh = directory.url.appendingPathComponent("fresh")
  let cached = directory.url.appendingPathComponent("cached")
  try SafeFile.makeDirectory(fresh)
  try SafeFile.makeDirectory(cached)
  let cancellation = try CancellationToken()
  let records = try await XcodeAndroidLicenses.prepare(
    output: fresh, previous: nil, cache: nil, cancellation: cancellation)
  #expect(!records.isEmpty)
  let replay = try await XcodeAndroidLicenses.prepare(
    output: cached, previous: records, cache: fresh, cancellation: cancellation)
  #expect(replay == records)
  let repository = try await HTTPData.get(
    URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!,
    maximumBytes: 8 << 20)
  var hashes = try XcodeAndroidLicenses.hashes(repository)
  for record in records {
    let licenses = try XcodeAndroidLicenses.hashes(
      SafeFile.read(Artifacts.resolve(record, under: fresh), limit: 8 << 20))
    for (name, values) in licenses { hashes[name, default: []].formUnion(values) }
  }
  let sdk = directory.url.appendingPathComponent("sdk")
  let licenses = sdk.appendingPathComponent("licenses")
  try SafeFile.makeDirectory(sdk)
  try SafeFile.makeDirectory(licenses)
  for (name, values) in hashes {
    try SafeFile.writeNew(
      Data((values.sorted().joined(separator: "\n") + "\n").utf8),
      to: licenses.appendingPathComponent(name))
  }
  let log = directory.url.appendingPathComponent("sdkmanager.log")
  try SafeFile.writeNew(Data(), to: log)
  let output = try FileHandle(forWritingTo: log)
  defer { try? output.close() }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
  process.arguments = [
    "-e", "alarm 120; exec @ARGV", ProcessInfo.processInfo.environment["MISO_SDKMANAGER"]!,
    "--sdk_root=\(sdk.path)", "--licenses",
  ]
  var environment = ProcessInfo.processInfo.environment
  environment["ANDROID_USER_HOME"] = directory.url.appendingPathComponent("android-user").path
  process.environment = environment
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
  #expect(process.terminationStatus == 0, "\(text)")
  #expect(text.contains("All SDK package licenses accepted"), "\(text)")
}

private func androidRepository() -> String {
  let versions = ["20.0", "37.0.1", "2", "36.0.0", "28.2.13676358"]
  let packages = zip(XcodeAndroidInputs.identifiers, versions).map { identifier, version in
    let revision = zip(["major", "minor", "micro"], version.split(separator: "."))
      .map { "<\($0)>\($1)</\($0)>" }.joined()
    let filename =
      identifier.hasPrefix("cmdline-tools;")
      ? "commandlinetools-mac-14742923_latest.zip" : "package.zip"
    return """
      <remotePackage path="\(identifier)">
      <type-details><api-level>36</api-level></type-details><display-name>Android tool</display-name>
      <revision>\(revision)</revision><channelRef ref="channel-0"/>
      <uses-license ref="android-sdk-license"/>
      <archives><archive><host-os>macosx</host-os><complete>
      <size>100</size><checksum type="sha1">\(String(repeating: "a", count: 40))</checksum>
      <url>\(filename)</url></complete></archive></archives></remotePackage>
      """
  }.joined()
  return """
    <sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:common="http://schemas.android.com/repository/android/common/02">
    <license id="android-sdk-license">License terms</license>\(packages)</sdk:sdk-repository>
    """
}

@Test func androidRepositoryPinsConfiguredPackagesAndRejectsDrift() throws {
  let source = androidRepository()
  let selection = try XcodeAndroidInputs.parse(Data(source.utf8))
  #expect(selection.packages.map(\.identifier) == XcodeAndroidInputs.identifiers)
  #expect(selection.packages.last?.revision == "28.2.13676358")
  #expect(selection.licenses == ["android-sdk-license": "License terms"])
  for (old, new) in [
    ("channel-0", "channel-1"), ("<major>20</major>", "<major>21</major>"),
    ("<api-level>36</api-level>", "<api-level>37</api-level>"),
    ("<size>100</size>", "<size>2147483649</size>"),
    ("<url>package.zip</url>", "<url>../package.zip</url>"),
    ("<archives>", "<dependencies/><archives>"),
    ("android-sdk-license", "unknown-license"),
    ("<host-os>macosx</host-os>", "<host-os>macosx</host-os><host-arch>x86_64</host-arch>"),
  ] {
    #expect(throws: MisoError.self) {
      try XcodeAndroidInputs.parse(Data(source.replacingOccurrences(of: old, with: new).utf8))
    }
  }
  #expect(throws: MisoError.self) {
    try XcodeAndroidInputs.parse(Data(("<!DOCTYPE unsafe>" + source).utf8))
  }
}

@Test func androidPropertiesRejectAmbiguityAndPreserveValues() throws {
  #expect(
    try XcodeAndroidInputs.properties(Data("# metadata\nPkg.Revision = 20.0\nvalue = a=b\n".utf8))
      == ["Pkg.Revision": "20.0", "value": "a=b"])
  for text in ["Pkg.Revision=1\nPkg.Revision=2", "=value", "malformed"] {
    #expect(throws: MisoError.self) { try XcodeAndroidInputs.properties(Data(text.utf8)) }
  }
}

@Test func androidInstallationUsesVendorPackageMetadataAndExactVersions() throws {
  let repository = Data(androidRepository().utf8)
  let selection = try XcodeAndroidInputs.parse(repository)
  let package = selection.packages[0]
  let xml = try XcodeAndroidMetadata.localPackage(repository, package: package)
  let root = try #require(XMLDocument(data: xml).rootElement())
  #expect(root.uri == "http://schemas.android.com/repository/android/common/02")
  let local = try #require(root.elements(forName: "localPackage").first)
  #expect(local.attribute(forName: "path")?.stringValue == "cmdline-tools;20.0")
  #expect(local.elements(forName: "archives").isEmpty)
  #expect(local.elements(forName: "channelRef").isEmpty)
  #expect(root.elements(forName: "license").first?.stringValue == "License terms")
  #expect(
    XcodeAndroidMetadata.licenseDigest("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
  #expect(XcodeAndroidMetadata.licenseDigest("abc\n") == XcodeAndroidMetadata.licenseDigest("abc"))
  #expect(
    XcodeAndroidMetadata.licenseDigest(" First  paragraph\n  continued.\n\n  Second paragraph. \n")
      == XcodeAndroidMetadata.licenseDigest("First paragraph continued.\n\nSecond paragraph."))
  #expect(
    XcodeAndroidMetadata.licenseDigest("a\nb") != XcodeAndroidMetadata.licenseDigest("a\n\nb"))
  let rows = selection.packages.map {
    "\($0.identifier) | \($0.revision) | Tool | \($0.identifier.replacingOccurrences(of: ";", with: "/"))"
  }.joined(separator: "\n")
  try XcodeAndroidInstallation.verifyInstalled(rows, selection: selection)
  for text in [
    rows + "\n" + rows, rows.replacingOccurrences(of: " | 20.0 |", with: " | 23.0 |"), "",
  ] {
    #expect(throws: MisoError.self) {
      try XcodeAndroidInstallation.verifyInstalled(text, selection: selection)
    }
  }
  let profile = try XcodeAndroidInstallation.shellProfile(Data("export OTHER=1\n".utf8))
  #expect(try XcodeAndroidInstallation.shellProfile(profile) == profile)
  #expect(String(decoding: profile, as: UTF8.self).contains("cmdline-tools/20.0/bin"))
}

@Test func androidCatalogLicensesNormalizeTermsAndRejectUnsafeSources() throws {
  let xml = Data(
    "<repository><license id=\"android-sdk-license\">abc\n</license></repository>".utf8)
  let hashes = try XcodeAndroidLicenses.hashes(xml)
  #expect(
    hashes["android-sdk-license"] == ["a9993e364706816aba3e25717850c26c9cd0d89d"])
  let prefix =
    "<common:site-list xmlns:common=\"http://schemas.android.com/repository/android/sites-common/1\">"
  for path in ["../escape.xml", "https://example.com/catalog.xml", "/absolute.xml"] {
    #expect(throws: MisoError.self) {
      try XcodeAndroidLicenses.sites(
        Data((prefix + "<site><url>\(path)</url></site></common:site-list>").utf8))
    }
  }
  #expect(throws: MisoError.self) {
    try XcodeAndroidLicenses.hashes(Data("<!DOCTYPE x><repository/>".utf8))
  }
}

import Foundation
import Testing

@testable import MisoCore

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
    XcodeAndroidMetadata.licenseDigest(" abc\n") == "a9993e364706816aba3e25717850c26c9cd0d89d")
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

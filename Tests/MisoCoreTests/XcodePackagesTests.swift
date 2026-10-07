import Foundation
import Testing

@testable import MisoCore

@Test func xcodePackagesUseTheIdentityInEachSignedPackage() throws {
  var configuration = XcodeConfiguration()
  configuration.version = "27.2"
  configuration.build = "27B5028f"
  let policies = try XcodePackages.Policy.standard(configuration)
  let core = Data(
    """
    <pkg-info identifier="com.apple.pkg.CoreTypes" version="27.1.0.9000000000.1788505170" useHFSPlusCompression="true" auth="root" />
    """.utf8)
  let resources = Data(
    """
    <pkg-info identifier="com.apple.pkg.XcodeSystemResources" version="27.1.0.0.1790739719" useHFSPlusCompression="true" auth="root" />
    """.utf8)
  #expect(try policies[0].validateInfo(core).identifier == "com.apple.pkg.CoreTypes")
  #expect(try policies[0].validateInfo(core).version == "27.1.0.9000000000.1788505170")
  #expect(try policies[3].validateInfo(resources).version == "27.1.0.0.1790739719")
  let variant = Data(
    String(decoding: core, as: UTF8.self)
      .replacingOccurrences(of: "pkg.CoreTypes", with: "pkg.CoreTypes.2000A36c").utf8)
  #expect(try policies[0].validateInfo(variant).identifier == "com.apple.pkg.CoreTypes.2000A36c")
  for identifier in ["com.apple.pkg.CoreTypesOther", "com.apple.pkg.CoreTypes.../other"] {
    let invalid = Data(
      String(decoding: core, as: UTF8.self)
        .replacingOccurrences(of: "com.apple.pkg.CoreTypes", with: identifier).utf8)
    #expect(throws: MisoError.self) { try policies[0].validateInfo(invalid) }
  }
}

@Test func xcodePackagePolicySeparatesFirmlinksFromRelocatedSystemFiles() throws {
  let policies = try XcodePackages.Policy.standard(.init())
  #expect(policies.count == 4)
  let coreTypes = policies[0]
  let library = "System/Library/CoreServices/CoreTypes.bundle/Contents/Library"
  #expect(
    try coreTypes.destination(library + "/MobileDevices.bundle") == library
      + "/MobileDevices.bundle")
  #expect(throws: MisoError.self) {
    try coreTypes.destination("System/Library/CoreServices/CoreTypes.bundle/Contents/Info.plist")
  }
  #expect(
    try policies[1].destination("System/Library/LaunchDaemons/daemon.plist")
      == "Library/Apple/System/Library/LaunchDaemons/daemon.plist")
  #expect(try policies[2].destination("usr/bin/rvictl") == "Library/Apple/usr/bin/rvictl")
  #expect(throws: MisoError.self) {
    try policies[3].destination("Library/Keychains/System.keychain")
  }
  #expect(throws: MisoError.self) {
    try policies[1].destination("System/Library/../../private/var/db")
  }
}

@Test func xcodePackageMetadataRetainsIdentityAndRelocationChecks() throws {
  let policy = try XcodePackages.Policy.standard(.init())[1]
  let xml = """
    <pkg-info identifier="com.apple.pkg.MobileDevice" version="4.0.0.0.1788417373" auth="root" useHFSPlusCompression="true" system-volume-group-install-location="/Library/Apple/" />
    """
  try policy.validateInfo(Data(xml.utf8))
  for changed in [
    xml.replacingOccurrences(of: "/Library/Apple/", with: "/System/"),
    xml.replacingOccurrences(of: "4.0.0.0.1788417373", with: ""),
    xml.replacingOccurrences(of: "pkg.MobileDevice", with: "pkg.Other"),
    xml.replacingOccurrences(of: "auth=\"root\"", with: "install-location=\"/\" auth=\"root\""),
  ] {
    #expect(throws: MisoError.self) { try policy.validateInfo(Data(changed.utf8)) }
  }
}

@Test func xcodeLicenseUsesTheSignedChannelAndLicenseID() throws {
  var configuration = XcodeConfiguration()
  configuration.version = "27.2"
  configuration.build = "27B5028f"
  let beta = try XcodePackageInstallation.licenseValues(
    ["licenseType": "Beta", "licenseID": "EA2003"], configuration: configuration)
  #expect(beta["IDELastBetaLicenseAgreedTo"] == "EA2003")
  #expect(beta["IDEXcodeVersionForAgreedToBetaLicense"] == "27.2")
  #expect(beta["IDELastGMLicenseAgreedTo"] == nil)
  let gm = try XcodePackageInstallation.licenseValues(
    ["licenseType": "GM", "licenseID": "EA2002"], configuration: configuration)
  #expect(gm["IDELastGMLicenseAgreedTo"] == "EA2002")
  for license in [
    ["licenseType": "unknown", "licenseID": "EA2002"],
    ["licenseType": "GM", "licenseID": ""], ["licenseType": "Beta"],
  ] {
    #expect(throws: MisoError.self) {
      try XcodePackageInstallation.licenseValues(license, configuration: configuration)
    }
  }
}

@Test func nativeXcodePackageMetadataProbe() throws {
  guard let path = ProcessInfo.processInfo.environment["MISO_XCODE_PACKAGE_PROBE"] else { return }
  let app = URL(fileURLWithPath: path)
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let journal = try ExecutionJournal(
    output: directory.url.appendingPathComponent("probe"), operation: "package-metadata-probe")
  try journal.perform {
    for policy in try XcodePackages.Policy.standard(.init()) {
      _ = try policy.identity(in: app, journal: journal)
    }
    return true
  }
}

@Test func scopedPackageInventoriesDoNotBroadenCommandLineTools() throws {
  let text = """
    .\t40755\t0\t0\t\t
    ./Library\t40755\t0\t0\t\t
    ./Library/Developer\t40755\t0\t80\t\t
    ./Library/Developer/Test.framework\t40755\t0\t80\t\t
    ./Library/Developer/Test.framework/Current\t120755\t0\t80\t1\tA
    """
  #expect(throws: MisoError.self) { try PackageInventory.parse(text) }
  let entries = try PackageInventory.parse(
    text, roots: ["Library/Developer/Test.framework"], linkRoot: "Library/Developer")
  #expect(entries.count == 4)
  for link in ["../../../etc", "/etc", "../../DeveloperOutside/A"] {
    let changed = text.replacingOccurrences(of: "\tA", with: "\t" + link)
    #expect(throws: MisoError.self) {
      try PackageInventory.parse(
        changed, roots: ["Library/Developer/Test.framework"], linkRoot: "Library/Developer")
    }
  }
}

@Test func packageLinksAreResolvedWithoutConsultingTheHostFilesystem() throws {
  let text = """
    ./System/Library/LaunchAgents/com.apple.mobiledeviceupdater.plist\t120755\t0\t0\t133\t../PrivateFrameworks/MobileDevice.framework/Versions/A/Resources/MobileDeviceUpdater.app/Contents/Resources/com.apple.mobiledeviceupdater.plist
    """
  let entries = try PackageInventory.parse(
    text, roots: ["System/Library"], linkRoot: "System/Library")
  #expect(entries.count == 1)
}

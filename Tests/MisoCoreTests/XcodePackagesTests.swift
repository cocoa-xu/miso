import Foundation
import Testing

@testable import MisoCore

@Test func xcodeRCUsesItsOwnSignedPackageIdentities() throws {
  var configuration = XcodeConfiguration()
  configuration.version = "27.1"
  configuration.build = "27A9275"
  let policies = try XcodePackages.Policy.standard(configuration)
  let core = Data(
    """
    <pkg-info identifier="com.apple.pkg.CoreTypes" version="27.1.0.9000000000.1788505170" useHFSPlusCompression="true" auth="root" />
    """.utf8)
  let resources = Data(
    """
    <pkg-info identifier="com.apple.pkg.XcodeSystemResources" version="27.1.0.0.1790739719" useHFSPlusCompression="true" auth="root" />
    """.utf8)
  try policies[0].validateInfo(core)
  try policies[3].validateInfo(resources)
  #expect(throws: MisoError.self) {
    try XcodePackages.Policy.standard(.init())[0].validateInfo(core)
  }
  #expect(throws: MisoError.self) {
    try XcodePackages.Policy.standard(.init())[3].validateInfo(resources)
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
  var future = XcodeConfiguration()
  future.build = "27A9269"
  #expect(throws: MisoError.self) { try XcodePackages.Policy.standard(future) }
}

@Test func xcodePackageMetadataMustMatchReviewedIdentityAndRelocation() throws {
  let policy = try XcodePackages.Policy.standard(.init())[1]
  let xml = """
    <pkg-info identifier="com.apple.pkg.MobileDevice" version="4.0.0.0.1788417373" auth="root" useHFSPlusCompression="true" system-volume-group-install-location="/Library/Apple/" />
    """
  try policy.validateInfo(Data(xml.utf8))
  for changed in [
    xml.replacingOccurrences(of: "/Library/Apple/", with: "/System/"),
    xml.replacingOccurrences(of: "1788417373", with: "1788417374"),
    xml.replacingOccurrences(of: "pkg.MobileDevice", with: "pkg.Other"),
    xml.replacingOccurrences(of: "auth=\"root\"", with: "install-location=\"/\" auth=\"root\""),
  ] {
    #expect(throws: MisoError.self) { try policy.validateInfo(Data(changed.utf8)) }
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

import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func platformPreferencesSelectOnlyConfiguredPlatformsAndPreserveSDKHistory() throws {
  var configuration = XcodeConfiguration()
  configuration.platforms = [.iOS, .watchOS]
  let key = "IDEPlatformsFirstLaunchPresentedSDKVersions-iphoneos"
  let builds = ["macosx": "26A425", "iphoneos": "24A94403", "watchos": "24R360"]
  let values = try XcodePlatformPreferences.values(
    builds: builds, configuration: configuration, existing: [key: ["24A400", "24A94403"]])
  #expect(values[key] as? [String] == ["24A400", "24A94403"])
  #expect(values["IDEPlatformsFirstLaunchSelected-iphoneos"] as? Bool == true)
  #expect(values["IDEPlatformsFirstLaunchSelected-watchos"] as? Bool == true)
  #expect(values["IDEPlatformsFirstLaunchSelected-appletvos"] as? Bool == false)
  #expect(values["IDEPlatformsFirstLaunchSelected-xros"] as? Bool == false)
  #expect(values["IDEPlatformsFirstLaunchPresentedSDKVersions-xros"] == nil)
  for invalid in [builds.filter { $0.key != "watchos" }, builds.merging(["xros": "24M361"]) { $1 }]
  {
    #expect(throws: MisoError.self) {
      try XcodePlatformPreferences.values(
        builds: invalid, configuration: configuration, existing: [:])
    }
  }
}

@Test func platformPreferencesReadActualSDKBuildsAndPreserveUnrelatedUserSettings() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let data = try GuestVolume(temporary.url)
  var configuration = XcodeConfiguration()
  configuration.platforms = [.iOS]
  func write(_ path: String, _ values: [String: Any]) throws {
    try data.mergePlist(path, values: values, uid: getuid(), gid: getgid())
  }
  try write(
    "private/var/db/dslocal/nodes/Default/users/admin.plist",
    [
      "uid": [String(max(getuid(), 501))], "gid": [String(max(getgid(), 20))],
      "home": ["/Users/admin"],
    ])
  let preferences = "Users/admin/Library/Preferences/com.apple.dt.Xcode.plist"
  try write(preferences, ["UnrelatedSetting": "preserved"])
  let app = configuration.applicationPath
  var sdks: [XcodeArchive.SDK] = []
  for (name, build) in ["macosx": "26A425", "iphoneos": "24A94403"] {
    try write(
      "\(app)/\(name)/System/Library/CoreServices/SystemVersion.plist",
      [
        "ProductBuildVersion": build, "ProductVersion": "27.1",
      ])
    try FileManager.default.createSymbolicLink(
      atPath: data.path("\(app)/\(name).sdk").path, withDestinationPath: name)
    sdks.append(.init(name: name, version: "27.1", path: name + ".sdk"))
  }
  let root = try data.directory(app).url
  let builds = try XcodePlatformPreferences.install(
    data: data, application: root, sdks: sdks, configuration: configuration, username: "admin")
  #expect(builds == ["macosx": "26A425", "iphoneos": "24A94403"])
  let saved = try data.plist(preferences)
  #expect(saved["UnrelatedSetting"] as? String == "preserved")
  #expect(
    saved["IDEPlatformsFirstLaunchPresentedSDKVersions-iphoneos"] as? [String] == ["24A94403"])
  #expect(try FileMetadata.inspect(data.path(preferences)).st_uid == max(getuid(), 501))
  try write(
    "\(app)/iphoneos/System/Library/CoreServices/SystemVersion.plist",
    [
      "ProductBuildVersion": "27.1"
    ])
  #expect(throws: MisoError.self) {
    try XcodePlatformPreferences.install(
      data: data, application: root, sdks: sdks, configuration: configuration, username: "admin")
  }
  #expect(try data.plist(preferences) as NSDictionary == saved as NSDictionary)
}

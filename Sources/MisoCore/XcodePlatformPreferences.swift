import Darwin
import Foundation

enum XcodePlatformPreferences {
  static let platforms: [String: XcodeConfiguration.Platform] = [
    "iphoneos": .iOS, "watchos": .watchOS, "appletvos": .tvOS, "xros": .visionOS,
  ]

  static func install(
    data: GuestVolume, application: URL, sdks: [XcodeArchive.SDK],
    configuration: XcodeConfiguration, username: String
  ) throws -> [String: String] {
    let account = try BaseImageStage.Account(username, data: data)
    let volume = try GuestVolume(application)
    var builds: [String: String] = [:]
    for sdk in sdks where sdk.name == "macosx" || platforms[sdk.name] != nil {
      let link = try volume.path(sdk.path, allowLeafLink: true)
      guard let resolved = realpath(link.path, nil) else {
        throw MisoError.system("Resolve platform SDK", errno)
      }
      defer { free(resolved) }
      let root = URL(fileURLWithPath: String(cString: resolved))
      guard root.path.hasPrefix(application.path + "/") else {
        throw MisoError.invalid("Platform SDK escapes Xcode")
      }
      let metadata = try GuestVolume(root).plist("System/Library/CoreServices/SystemVersion.plist")
      guard let build = metadata["ProductBuildVersion"] as? String,
        build.range(of: #"\A[0-9]{2}[A-Z][0-9]{1,6}[a-z]?\z"#, options: .regularExpression) != nil,
        builds.updateValue(build, forKey: sdk.name) == nil
      else { throw MisoError.invalid("Invalid platform SDK build: \(sdk.name)") }
    }
    let path = "Users/\(username)/Library/Preferences/com.apple.dt.Xcode.plist"
    let existing = try data.contains(path) ? data.plist(path) : [:]
    let preferences = try values(builds: builds, configuration: configuration, existing: existing)
    try data.mergePlist(path, values: preferences, uid: account.uid, gid: account.gid)
    return builds
  }

  static func values(
    builds: [String: String], configuration: XcodeConfiguration, existing: [String: Any]
  ) throws -> [String: Any] {
    let selected = Set(platforms.filter { configuration.platforms.contains($0.value) }.keys)
    guard Set(builds.keys) == selected.union(["macosx"]) else {
      throw MisoError.invalid("Platform preferences require every configured SDK")
    }
    var values: [String: Any] = [:]
    for name in platforms.keys {
      values["IDEPlatformsFirstLaunchSelected-" + name] = selected.contains(name)
    }
    for (name, build) in builds {
      let key = "IDEPlatformsFirstLaunchPresentedSDKVersions-" + name
      let previous = existing[key] as? [String] ?? []
      values[key] = Array(Set(previous + [build])).sorted()
    }
    return values
  }
}

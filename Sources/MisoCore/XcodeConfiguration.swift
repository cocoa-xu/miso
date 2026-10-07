import Foundation

public struct XcodeConfiguration: Codable, Equatable, Sendable {
  public enum Platform: String, Codable, CaseIterable, Sendable {
    case iOS, watchOS, tvOS, visionOS

    var assetType: String {
      let name: String
      switch self {
      case .iOS: name = "iOS"
      case .watchOS: name = "watchOS"
      case .tvOS: name = "appleTVOS"
      case .visionOS: name = "xrOS"
      }
      return "com.apple.MobileAsset." + name + "SimulatorRuntime"
    }

    var simulatorIdentifier: String {
      let name: String
      switch self {
      case .iOS: name = "iphonesimulator"
      case .watchOS: name = "watchsimulator"
      case .tvOS: name = "appletvsimulator"
      case .visionOS: name = "xrsimulator"
      }
      return "com.apple.platform." + name
    }

    var sdkNames: [String: String] {
      switch self {
      case .iOS: ["iPhoneOS": "iphoneos", "iPhoneSimulator": "iphonesimulator"]
      case .watchOS: ["WatchOS": "watchos", "WatchSimulator": "watchsimulator"]
      case .tvOS: ["AppleTVOS": "appletvos", "AppleTVSimulator": "appletvsimulator"]
      case .visionOS: ["XROS": "xros", "XRSimulator": "xrsimulator"]
      }
    }
  }

  public enum Component: String, Codable, Sendable { case metalToolchain = "MetalToolchain" }

  public var schemaVersion = 1
  public var version = "27.0"
  public var build = "27A266a"
  public var platforms = Platform.allCases
  public var components: [Component] = [.metalToolchain]
  public var runtimeArchitecture = "arm64"
  public var profile: XcodeBuildProfile?

  public init() {}

  public func validate() throws {
    _ = try StableVersion(version)
    guard schemaVersion == 1,
      build.range(of: #"\A[0-9]{2}[A-Z][0-9]{1,6}[a-z]?\z"#, options: .regularExpression) != nil,
      Set(platforms).count == platforms.count,
      Set(components).count == components.count, runtimeArchitecture == "arm64"
    else { throw MisoError.invalid("Invalid Xcode configuration") }
    if let profile {
      try profile.validate()
      guard profile.platforms == platforms else {
        throw MisoError.invalid("Xcode platforms differ from the build profile")
      }
    }
  }

  var applicationPath: String { "Applications/Xcode_\(version).app" }

  var buildProfile: XcodeBuildProfile {
    var result = profile ?? .init()
    result.platforms = platforms
    return result
  }
}

import Foundation

public struct XcodeConfiguration: Codable, Equatable, Sendable {
  public enum Platform: String, Codable, CaseIterable, Sendable {
    case iOS, watchOS, tvOS, visionOS

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

  public init() {}

  public func validate() throws {
    _ = try StableVersion(version)
    guard schemaVersion == 1,
      build.range(of: #"\A[0-9]{2}[A-Z][0-9]{1,6}[a-z]?\z"#, options: .regularExpression) != nil,
      !platforms.isEmpty, Set(platforms).count == platforms.count,
      Set(components).count == components.count, runtimeArchitecture == "arm64"
    else { throw MisoError.invalid("Invalid Xcode configuration") }
  }

  var applicationPath: String { "Applications/Xcode_\(version).app" }
}

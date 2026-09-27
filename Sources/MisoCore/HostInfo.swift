import Foundation

public struct HostInfo: Encodable, Sendable {
  public let productVersion: String
  public let productBuild: String
  public let architecture: String
  public let physicalMemory: UInt64
  public let capturedAt: Date

  public static func current() throws -> Self {
    let data = try SafeFile.read(
      URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"), limit: 1 << 20)
    let metadata = try RestoreInspection.plist(data)
    guard let version = metadata["ProductVersion"] as? String,
      let build = metadata["ProductBuildVersion"] as? String
    else { throw MisoError.invalid("Missing host OS metadata") }
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    return Self(
      productVersion: version, productBuild: build, architecture: architecture,
      physicalMemory: ProcessInfo.processInfo.physicalMemory, capturedAt: Date())
  }
}

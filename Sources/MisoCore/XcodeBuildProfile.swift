import Foundation
import Yams

public struct XcodeBuildProfile: Codable, Equatable, Sendable {
  public var platforms = XcodeConfiguration.Platform.allCases
  public var trimIntel = false
  public var transparentCompression = true
  public var cleanup = true
  public var sparsify = true

  public init() {}

  public static var slim: Self {
    var result = Self()
    result.platforms = [.iOS, .watchOS]
    result.trimIntel = true
    return result
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case platforms, trimIntel, transparentCompression, cleanup, sparsify
  }

  public init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    platforms =
      try values.decodeIfPresent([XcodeConfiguration.Platform].self, forKey: .platforms)
      ?? platforms
    trimIntel = try values.decodeIfPresent(Bool.self, forKey: .trimIntel) ?? trimIntel
    transparentCompression =
      try values.decodeIfPresent(Bool.self, forKey: .transparentCompression)
      ?? transparentCompression
    cleanup = try values.decodeIfPresent(Bool.self, forKey: .cleanup) ?? cleanup
    sparsify = try values.decodeIfPresent(Bool.self, forKey: .sparsify) ?? sparsify
    try validate()
  }

  public static func read(_ url: URL) throws -> Self {
    let bytes = try SafeFile.read(url, limit: 64 << 10)
    guard let text = String(data: bytes, encoding: .utf8),
      let mapping = try compose(yaml: text)?.mapping
    else { throw MisoError.invalid("Expected an Xcode profile YAML mapping") }
    let allowed = Set(CodingKeys.allCases.map(\.rawValue))
    var seen = Set<String>()
    for (key, _) in mapping {
      guard let name = key.string, allowed.contains(name), seen.insert(name).inserted else {
        throw MisoError.invalid("Unknown or duplicate Xcode profile option: \(key)")
      }
    }
    return try YAMLDecoder().decode(Self.self, from: text)
  }

  func validate() throws {
    guard Set(platforms).count == platforms.count else {
      throw MisoError.invalid("Duplicate Xcode profile platforms")
    }
  }
}

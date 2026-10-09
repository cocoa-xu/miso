import Foundation
import Yams

public struct XcodeBuildProfile: Codable, Equatable, Sendable {
  public enum Preset: String, Codable, Sendable { case slim }
  public var preset: Preset?
  public var platforms = XcodeConfiguration.Platform.allCases
  public var trimIntel = false
  public var transparentCompression = true
  public var cleanup = true
  public var sparsify = true
  public var system = SystemPolicy()

  public init() {}

  public static var slim: Self {
    var result = Self()
    result.platforms = [.iOS, .watchOS]
    result.trimIntel = true
    result.preset = .slim
    result.system = .slim
    return result
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case preset, platforms, trimIntel, transparentCompression, cleanup, sparsify, system
  }

  public init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    if try values.decodeIfPresent(Preset.self, forKey: .preset) == .slim { self = .slim }
    platforms =
      try values.decodeIfPresent([XcodeConfiguration.Platform].self, forKey: .platforms)
      ?? platforms
    trimIntel = try values.decodeIfPresent(Bool.self, forKey: .trimIntel) ?? trimIntel
    transparentCompression =
      try values.decodeIfPresent(Bool.self, forKey: .transparentCompression)
      ?? transparentCompression
    cleanup = try values.decodeIfPresent(Bool.self, forKey: .cleanup) ?? cleanup
    sparsify = try values.decodeIfPresent(Bool.self, forKey: .sparsify) ?? sparsify
    if let overrides = try values.decodeIfPresent(SystemPolicy.self, forKey: .system) {
      system = system.merging(overrides)
    }
    try validate()
  }

  public static func read(_ url: URL) throws -> Self {
    let bytes = try SafeFile.read(url, limit: 64 << 10)
    guard let text = String(data: bytes, encoding: .utf8),
      let mapping = try compose(yaml: text)?.mapping
    else { throw MisoError.invalid("Expected an Xcode profile YAML mapping") }
    let allowed = Set(CodingKeys.allCases.map(\.rawValue))
    var seen = Set<String>()
    for (key, value) in mapping {
      guard let name = key.string, allowed.contains(name), seen.insert(name).inserted else {
        throw MisoError.invalid("Unknown or duplicate Xcode profile option: \(key)")
      }
      if name == "system" { try validateSystemYAML(value) }
    }
    return try YAMLDecoder().decode(Self.self, from: text)
  }

  func validate() throws {
    try system.validate()
    guard Set(platforms).count == platforms.count else {
      throw MisoError.invalid("Duplicate Xcode profile platforms")
    }
  }

  static func validateSystemYAML(_ node: Node) throws {
    guard let mapping = node.mapping else {
      throw MisoError.invalid("Expected a system policy YAML mapping")
    }
    var seen = Set<String>()
    for (key, value) in mapping {
      guard let name = key.string, SystemPolicy.CodingKeys(rawValue: name) != nil,
        seen.insert(name).inserted, let entries = value.mapping
      else { throw MisoError.invalid("Unknown, duplicate or invalid system policy option: \(key)") }
      var keys = Set<String>()
      for (key, _) in entries {
        guard let name = key.string, keys.insert(name).inserted else {
          throw MisoError.invalid("Duplicate or invalid system policy key: \(key)")
        }
      }
    }
  }
}

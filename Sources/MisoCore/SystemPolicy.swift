import Foundation
import Yams

public struct SystemPolicy: Codable, Equatable, Sendable {
  public enum ServiceState: String, Codable, Sendable { case disabled, enabled, unchanged }

  public var features: [String: ServiceState] = [:]
  public var services: [String: ServiceState] = [:]
  public var settings: [String: Bool] = [:]

  public init() {}

  public static var serviceCatalog: [String: [String]] { SystemServiceCatalog.features }

  public static func read(_ url: URL) throws -> Self {
    let bytes = try SafeFile.read(url, limit: 64 << 10)
    guard let text = String(data: bytes, encoding: .utf8), let node = try compose(yaml: text) else {
      throw MisoError.invalid("Expected a system policy YAML mapping")
    }
    try XcodeBuildProfile.validateSystemYAML(node)
    return try YAMLDecoder().decode(Self.self, from: text)
  }

  public static var slim: Self {
    var result = Self()
    result.features = Dictionary(
      uniqueKeysWithValues: SystemServiceCatalog.features.keys.map { ($0, .disabled) })
    result.settings = [
      "automaticOSUpdates": false, "automaticAppUpdates": false,
      "securityDataUpdates": true, "automaticBackups": false, "sessionRestore": false,
      "spotlightIndexing": false,
    ]
    return result
  }

  enum CodingKeys: String, CodingKey, CaseIterable { case features, services, settings }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    features = try values.decodeIfPresent([String: ServiceState].self, forKey: .features) ?? [:]
    services = try values.decodeIfPresent([String: ServiceState].self, forKey: .services) ?? [:]
    settings = try values.decodeIfPresent([String: Bool].self, forKey: .settings) ?? [:]
    try validate()
  }

  static let settingNames: Set<String> = [
    "automaticOSUpdates", "automaticAppUpdates", "securityDataUpdates", "automaticBackups",
    "sessionRestore", "spotlightIndexing", "reduceMotion", "reduceTransparency",
  ]

  func validate() throws {
    for name in features.keys where SystemServiceCatalog.features[name] == nil {
      throw MisoError.invalid("Unknown system feature: \(name)")
    }
    for name in settings.keys where !Self.settingNames.contains(name) {
      throw MisoError.invalid("Unknown system setting: \(name)")
    }
    for label in services.keys {
      guard
        label.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression)
          != nil
      else { throw MisoError.invalid("Invalid launchd service label: \(label)") }
    }
  }

  func merging(_ overrides: Self) -> Self {
    var result = self
    result.features.merge(overrides.features) { _, new in new }
    result.services.merge(overrides.services) { _, new in new }
    result.settings.merge(overrides.settings) { _, new in new }
    return result
  }

  var resolvedServices: [String: ServiceState] {
    var result: [String: ServiceState] = [:]
    for feature in features.keys.sorted() {
      for label in SystemServiceCatalog.features[feature] ?? [] {
        result[label] = features[feature]
      }
    }
    result.merge(services) { _, new in new }
    return result
  }

  var isEmpty: Bool { features.isEmpty && services.isEmpty && settings.isEmpty }
}

import Foundation

public struct BaseBuildRecipe: Codable {
  enum Stage: String, Codable, CaseIterable {
    case `static`, bootstrap, bottles, ruby, packages, taps, gcm, security, settings, certificates

    var fileKeys: Set<String> {
      switch self {
      case .static: ["runner", "runner-release", "known-hosts"]
      case .bootstrap: ["archive"]
      case .bottles: ["resolution"]
      default: ["plan"]
      }
    }

    var directoryKeys: Set<String> {
      switch self {
      case .static, .settings, .bootstrap: []
      case .bottles: ["bottles"]
      case .security: ["boot", "material"]
      default: ["inputs"]
      }
    }

    var command: [String] {
      switch self {
      case .bottles: ["base", "bottles", "install"]
      case .ruby, .packages, .taps, .gcm: ["base", rawValue, "install"]
      case .certificates: ["base", "ca", "install"]
      default: ["base", rawValue]
      }
    }

    var operation: String {
      switch self {
      case .settings: "base-system-settings"
      default: "base-" + rawValue
      }
    }

    var timeout: TimeInterval {
      switch self {
      case .ruby: 14_400
      case .bottles: 3600
      default: 1800
      }
    }
  }

  struct Step: Codable {
    let stage: Stage
    let files: [String: ImageBundle.FileRecord]
    let directories: [String: String]
    let formulae: [String]?

    func validate() throws {
      guard Set(files.keys) == stage.fileKeys, Set(directories.keys) == stage.directoryKeys else {
        throw MisoError.invalid("Unexpected Base recipe inputs for \(stage.rawValue)")
      }
      for record in files.values {
        _ = try SafeFile.relativePath(record.path)
        try SafeFile.validateSHA256(record.sha256)
        guard record.bytes > 0 else { throw MisoError.invalid("Empty Base recipe input") }
      }
      for path in directories.values { _ = try SafeFile.relativePath(path) }
      if stage == .bootstrap,
        (files["archive"]!.path as NSString).lastPathComponent != "archive.json"
      {
        throw MisoError.invalid("Expected an input archive manifest")
      }
      if stage == .bottles,
        (files["resolution"]!.path as NSString).lastPathComponent != "resolution.json"
      {
        throw MisoError.invalid("Expected a formula resolution manifest")
      }
      if stage == .bottles {
        guard let formulae, (1...256).contains(formulae.count),
          Set(formulae).count == formulae.count
        else {
          throw MisoError.invalid("Invalid recipe formula selection")
        }
        for formula in formulae { try PackageRequest(name: formula).validate() }
      } else if formulae != nil {
        throw MisoError.invalid("Formula selection belongs to the bottles stage")
      }
    }
  }

  let schemaVersion: Int
  let target: MacOSRelease
  let username: String
  let steps: [Step]

  func validate() throws {
    _ = try RestoreProfile.select(target)
    guard schemaVersion == 1, steps.map(\.stage) == Stage.allCases,
      username.range(of: #"\A[a-z][a-z0-9_-]{0,30}\z"#, options: .regularExpression) != nil
    else { throw MisoError.invalid("Base recipe must contain every stage in construction order") }
    for step in steps { try step.validate() }
  }

  func arguments(for step: Step, inputs: GuestVolume, nodeFormula: String) throws -> [String] {
    try step.validate()
    var arguments = step.stage.command
    for key in step.files.keys.sorted() {
      let file = try inputs.path(step.files[key]!.path)
      let path =
        step.stage == .bootstrap || step.stage == .bottles ? file.deletingLastPathComponent() : file
      arguments += ["--" + key, path.path]
    }
    for key in step.directories.keys.sorted() {
      arguments += ["--" + key, try inputs.directory(step.directories[key]!).url.path]
    }
    if step.stage != .settings { arguments += ["--username", username] }
    if step.stage == .static { arguments += ["--node-formula", nodeFormula] }
    if let formulae = step.formulae {
      for name in formulae { arguments += ["--formula", name] }
      arguments += ["--post-install"]
    }
    return arguments
  }
}

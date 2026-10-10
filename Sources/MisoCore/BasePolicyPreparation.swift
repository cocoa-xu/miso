import Darwin
import Foundation

@MainActor
public enum BasePolicyPreparation {
  public struct Receipt: Codable {
    let target: MacOSRelease
    let files: [ImageBundle.FileRecord]
    let originalsUnchanged: Bool
    let vmStarted: Bool
  }

  public static func run(
    source: URL, security: URL, settings: URL, output: URL,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Inspecting Base policy inputs requires administrator privileges")
    }
    let volume = try GuestVolume(source)
    let manifest = try SafeFile.read(volume.path("manifest.json"), limit: 1 << 20)
    guard let fields = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
      let release = fields["target"] as? [String: String],
      let version = release["version"], let build = release["build"]
    else { throw MisoError.invalid("Missing Vanilla target") }
    let target = MacOSRelease(version: version, build: build)
    try BasePipeline.requireVanilla(manifest, target: target)
    let securityPlan = try JSON.read(BaseSecurity.Plan.self, from: security)
    let settingsPlan = try JSON.read(BaseSystemSettings.Plan.self, from: settings)
    try securityPlan.validate()
    try settingsPlan.validate()
    guard securityPlan.target == settingsPlan.target,
      try RestoreProfile.select(target).family == RestoreProfile.select(securityPlan.target).family
    else { throw MisoError.invalid("Base policy template belongs to a different macOS family") }
    let original = try ImageBundle.snapshot(source)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-base-policy", cancellation: cancellation)
    return try journal.perform {
      let session = try DiskImageSession(
        image: volume.path("disk.img"), readOnly: true, journal: journal)
      try session.withAttachment { session in
        let main = try BaseImageStage.mainContainer(session)
        let system = try ImageMounts.mount(
          main.volume(role: "System"), session: session, journal: journal,
          name: "policy-system", readOnly: true)
        let tccd = try system.path("System/Library/PrivateFrameworks/TCC.framework/Support/tccd")
        _ = try BaseTCC.schema(
          in: SafeFile.read(tccd, limit: 64 << 20), version: securityPlan.tccSchemaVersion,
          sha256: securityPlan.tccSchemaSHA256)
        var securityFields = try object(security)
        var settingsFields = try object(settings)
        let identity = ["version": version, "build": build]
        securityFields["target"] = identity
        settingsFields["target"] = identity
        func digest(_ path: String) throws -> String {
          let file = try system.path(path)
          try AppleCode.validate(file, scope: .executable)
          return try SafeFile.sha256(file)
        }
        securityFields["csrutilSHA256"] = try digest("usr/bin/csrutil")
        securityFields["tccdSHA256"] = try digest(
          "System/Library/PrivateFrameworks/TCC.framework/Support/tccd")
        if var reminder = securityFields["captureReminder"] as? [String: Any] {
          reminder["replaydSHA256"] = try digest("usr/libexec/replayd")
          securityFields["captureReminder"] = reminder
        }
        settingsFields["mdsSHA256"] = try digest(
          "System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds")
        for (name, value) in [("security", securityFields), ("settings", settingsFields)] {
          try SafeFile.writeNew(
            JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
            to: output.appendingPathComponent(name + ".json"))
        }
      }
      try JSON.read(BaseSecurity.Plan.self, from: output.appendingPathComponent("security.json"))
        .validate()
      try JSON.read(BaseSystemSettings.Plan.self, from: output.appendingPathComponent("settings.json"))
        .validate()
      guard try ImageBundle.snapshot(source) == original else {
        throw MisoError.invalid("Vanilla changed during policy inspection")
      }
      let files = try ["security.json", "settings.json"].map {
        try Artifacts.record(output.appendingPathComponent($0), relativeTo: output)
      }
      return Receipt(target: target, files: files, originalsUnchanged: true, vmStarted: false)
    }
  }

  private static func object(_ url: URL) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: SafeFile.read(url, limit: 1 << 20))
      as? [String: Any]
    else { throw MisoError.invalid("Invalid Base policy template") }
    return value
  }
}

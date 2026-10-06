import Darwin
import Foundation

public enum BaseSystemSettings {
  public struct Plan: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let mdsSHA256: String
    let indexVersion: Int
    let tartVersion: String

    func validate() throws {
      _ = try RestoreProfile.select(target)
      try SafeFile.validateSHA256(mdsSHA256)
      try PackageRequest(name: "tart-guest-agent", version: tartVersion).validate()
      guard schemaVersion == 1, (1...1000).contains(indexVersion) else {
        throw MisoError.invalid("Invalid Base system settings plan")
      }
    }
  }

  public struct Details: Codable {
    let plan: Plan
    let files: [ImageBundle.FileRecord]
    let vendorBinary: ImageBundle.FileRecord
    let detachedPayloadVerified: Bool
    let tartRuntimeVerified: Bool
    let spotlightRuntimeVerified: Bool
  }

  private static let wrapper = "usr/local/libexec/miso-tart-supervisor"
  private static let mds =
    "System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds"
  private static let services = [
    "Library/LaunchDaemons/dev.macos-image.tart-guest-daemon.plist",
    "Library/LaunchAgents/dev.macos-image.tart-guest-agent.plist",
  ]
  private static let stores = [
    ("System", "private/var/db/Spotlight-V100/BootVolume"),
    ("Data", ".Spotlight-V100"), ("Preboot", "private/var/db/Spotlight-V100/Preboot"),
  ]

  public static func run(
    source: URL, plan planURL: URL, output: URL,
    cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planHash = try SafeFile.sha256(planURL)
    let plan = try JSON.read(Plan.self, from: planURL)
    try plan.validate()
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-system-settings", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == plan.target else { throw MisoError.invalid("Base settings target mismatch") }
      try journal.setMetadata("settingsPlan", value: plan)
      let image = bundle.appendingPathComponent("disk.img")
      try verifySystem(image, plan: plan, journal: journal)
      let installed = try install(image, plan: plan, journal: journal)
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let main = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "settings-audit",
          readOnly: true)
        for record in installed.files {
          let path = try Artifacts.resolve(
            record, under: data.root, cancellation: journal.cancellation)
          try verifyMetadata(path, relative: record.path)
        }
        _ = try Artifacts.resolve(
          installed.vendorBinary, under: data.root, cancellation: journal.cancellation)
      }
      guard try SafeFile.sha256(planURL) == planHash else {
        throw MisoError.invalid("Base settings plan changed")
      }
      return installed
    }
  }

  private static func verifySystem(_ image: URL, plan: Plan, journal: ExecutionJournal) throws {
    let read = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try read.withAttachment { session in
      let main = try BaseImageStage.mainContainer(session)
      let system = try ImageMounts.mount(
        main.volume(role: "System"), session: session, journal: journal, name: "settings-system",
        readOnly: true)
      guard try SafeFile.sha256(system.path(mds)) == plan.mdsSHA256 else {
        throw MisoError.invalid("Target Spotlight implementation differs from plan")
      }
    }
  }

  private static func install(_ image: URL, plan: Plan, journal: ExecutionJournal) throws -> Details
  {
    let write = try DiskImageSession(image: image, readOnly: false, journal: journal)
    return try write.withAttachment { session in
      let main = try BaseImageStage.mainContainer(session)
      let data = try ImageMounts.mount(
        main.volume(role: "Data"), session: session, journal: journal, name: "settings-data",
        readOnly: false)
      let agent = "opt/homebrew/Cellar/tart-guest-agent/\(plan.tartVersion)/bin/tart-guest-agent"
      let vendor = try Artifacts.record(data.path(agent), relativeTo: data.root)
      guard !(try data.contains(wrapper)) else {
        throw MisoError.invalid("Tart supervisor already exists")
      }
      try data.makeDirectories((wrapper as NSString).deletingLastPathComponent)
      try data.write(wrapper, data: Data(supervisor.utf8), mode: 0o755)
      var files = [wrapper]
      for service in services {
        try BuildProgress.run("Configure service \((service as NSString).lastPathComponent)") {
          let role = service.contains("LaunchDaemons/") ? "daemon" : "agent"
          let settings = try supervisedService(data.plist(service), role: role)
          try data.write(
            service,
            data: PropertyListSerialization.data(
              fromPropertyList: settings, format: .binary, options: 0))
          guard NSDictionary(dictionary: try data.plist(service)).isEqual(to: settings) else {
            throw MisoError.invalid("Tart service readback differs")
          }
          files.append(service)
        }
      }
      let created = Date(
        timeIntervalSince1970: floor(journal.record.startedAt.timeIntervalSince1970))
      let modified = Date()
      try data.makeDirectories("private/var/db/Spotlight-V100")
      guard chmod(try data.path("private/var/db/Spotlight-V100").path, 0o700) == 0 else {
        throw MisoError.system("Set Spotlight root mode", errno)
      }
      for (role, directory) in stores {
        try BuildProgress.run("Disable Spotlight indexing on \(role)") {
          let path = directory + "/VolumeConfiguration.plist"
          guard !(try data.contains(path)) else {
            throw MisoError.invalid("Existing Spotlight configuration needs a merge")
          }
          let configuration = try spotlight(
            plan, volume: main.volume(role: role).identifier, store: UUID(), created: created,
            modified: modified)
          try data.makeDirectories(directory)
          guard chmod(try data.path(directory).path, 0o700) == 0 else {
            throw MisoError.system("Set Spotlight directory mode", errno)
          }
          try data.write(
            path,
            data: PropertyListSerialization.data(
              fromPropertyList: configuration, format: .binary, options: 0), mode: 0o600)
          guard NSDictionary(dictionary: try data.plist(path)).isEqual(to: configuration) else {
            throw MisoError.invalid("Spotlight readback differs")
          }
          files.append(path)
        }
      }
      guard try Artifacts.record(data.path(agent), relativeTo: data.root) == vendor else {
        throw MisoError.invalid("Tart vendor binary changed")
      }
      let records = try files.map { path in
        let url = try data.path(path)
        try verifyMetadata(url, relative: path)
        return try Artifacts.record(url, relativeTo: data.root)
      }
      return Details(
        plan: plan, files: records, vendorBinary: vendor, detachedPayloadVerified: true,
        tartRuntimeVerified: false, spotlightRuntimeVerified: false)
    }
  }

  static func supervisedService(_ original: [String: Any], role: String) throws -> [String: Any] {
    guard ["daemon", "agent"].contains(role),
      original["ProgramArguments"] as? [String] == [
        "/opt/homebrew/bin/tart-guest-agent", "--run-" + role,
      ],
      original["Label"] as? String == "dev.macos-image.tart-guest-" + role,
      original["Disabled"] == nil || original["Disabled"] is Bool
    else {
      throw MisoError.invalid("Unexpected source Tart service")
    }
    var result = original
    result.removeValue(forKey: "Disabled")
    result["ProgramArguments"] = [
      "/bin/sh", "/" + wrapper, "/opt/homebrew/bin/tart-guest-agent", "--run-" + role,
    ]
    result["KeepAlive"] = ["SuccessfulExit": false]
    return result
  }

  static func spotlight(_ plan: Plan, volume: UUID, store: UUID, created: Date, modified: Date)
    throws -> [String: Any]
  {
    try plan.validate()
    guard modified > created else {
      throw MisoError.invalid("Spotlight policy must follow store creation")
    }
    let version = "Version \(plan.target.version) (Build \(plan.target.build))"
    return [
      "ConfigurationVolumeUUID": volume.uuidString, "ConfigurationCreationDate": created,
      "ConfigurationCreationVersion": version, "ConfigurationModificationDate": modified,
      "ConfigurationModificationVersion": version, "ConfigurationWriteback": false,
      "Exclusions": [String](),
      "Options": ["ConfigurationType": "Default"],
      "Stores": [
        store.uuidString: [
          "PartialPath": "/", "IndexVersion": plan.indexVersion,
          "CreationDate": created, "CreationVersion": version, "PolicyDate": modified,
          "PolicyLevel": "kMDConfigSearchLevelFSSearchOnly", "PolicyProcess": "mdutil",
          "PolicyVersion": version,
        ]
      ],
    ]
  }

  private static func verifyMetadata(_ url: URL, relative: String) throws {
    let info = try FileMetadata.inspect(url)
    let mode: mode_t =
      relative == wrapper ? 0o755 : relative.hasSuffix("VolumeConfiguration.plist") ? 0o600 : 0o644
    guard info.st_uid == 0, info.st_gid == 0, info.st_mode == S_IFREG | mode else {
      throw MisoError.invalid("Base settings metadata differs")
    }
  }

  static let supervisor = """
    #!/bin/sh
    set -u
    child=
    stop() {
      trap '' TERM INT HUP
      if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
      fi
      exit 0
    }
    trap stop TERM INT HUP
    [ "$#" -ge 1 ] || exit 64
    "$@" &
    child=$!
    wait "$child"
    exit "$?"

    """
}

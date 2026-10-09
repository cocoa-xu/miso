import Darwin
import Foundation

public enum ImageOptimization {
  struct Details: Codable {
    let compression: TransparentCompression.Receipt?
    let compaction: APFSCompaction.Receipt?
    var cleanedPaths: [String] = []
    var systemPolicy: OfflineSystemPolicy.Receipt?
  }

  public struct Receipt: Encodable {
    let bundle: String
    let files: [ImageBundle.FileRecord]
    let optimization: Details
    let sourceContentVerified = false
    let vmStarted = false
    let runtimeVerified = false
  }

  public static func run(
    source: URL, output: URL, username: String = "admin", compress: Bool = true,
    systemPolicy: SystemPolicy? = nil,
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Image optimization requires administrator privileges")
    }
    let manifestURL = source.appendingPathComponent("manifest.json")
    let original = try SafeFile.read(manifestURL, limit: 1 << 20)
    let inventory = try JSONDecoder().decode(ImageBundle.Manifest.self, from: original)
    try inventory.validate()
    guard var manifest = try JSONSerialization.jsonObject(with: original) as? [String: Any],
      manifest["construction_vm_started"] as? Bool == false,
      manifest["runtime_verified"] as? Bool == false
    else { throw MisoError.invalid("Optimization requires a never-booted native bundle") }
    let snapshot = try ImageBundle.snapshot(source)
    for file in inventory.files {
      guard snapshot[file.path]?.bytes == file.bytes else {
        throw MisoError.invalid("Bundle file size differs from manifest")
      }
    }
    let journal = try ExecutionJournal(
      output: output, operation: "optimize-bundle", cancellation: cancellation)
    return try journal.perform {
      let origin = try DiskImageSession(
        image: source.appendingPathComponent("disk.img"), readOnly: true, journal: journal)
      try origin.requireDetached()
      let bundle = output.appendingPathComponent("bundle")
      try SafeFile.makeDirectory(bundle)
      for name in ImageBundle.requiredFiles.sorted() {
        try Artifacts.clone(
          source.appendingPathComponent(name), to: bundle.appendingPathComponent(name))
      }
      let configuration = manifest["xcode_configuration"] as? [String: Any]
      let application: String?
      var profile: XcodeBuildProfile?
      if let configuration {
        let xcode = try JSONDecoder().decode(
          XcodeConfiguration.self, from: JSONSerialization.data(withJSONObject: configuration))
        try xcode.validate()
        application = xcode.applicationPath
        profile = xcode.buildProfile
      } else {
        application = nil
      }
      if let systemPolicy {
        try systemPolicy.validate()
        var selected = profile ?? XcodeBuildProfile()
        selected.system = selected.system.merging(systemPolicy)
        profile = selected
        if let configuration {
          var xcode = try JSONDecoder().decode(
            XcodeConfiguration.self, from: JSONSerialization.data(withJSONObject: configuration))
          xcode.profile = selected
          manifest["xcode_configuration"] = try JSONSerialization.jsonObject(
            with: JSON.encode(xcode))
        }
      }
      let result = try apply(
        bundle: bundle, username: username, application: application,
        compress: compress, profile: profile, journal: journal)
      try origin.requireDetached()
      guard try ImageBundle.snapshot(source) == snapshot,
        try SafeFile.read(manifestURL, limit: 1 << 20) == original
      else { throw MisoError.invalid("Optimization source changed") }
      let files = try journal.measure("outputHashingSeconds") {
        try ImageBundle.requiredFiles.sorted().map {
          try Artifacts.record(
            bundle.appendingPathComponent($0), relativeTo: bundle,
            cancellation: journal.cancellation)
        }
      }
      manifest["files"] = try JSONSerialization.jsonObject(with: JSON.encode(files))
      manifest["optimization"] = try JSONSerialization.jsonObject(with: JSON.encode(result))
      try SafeFile.writeNew(
        JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
        to: bundle.appendingPathComponent("manifest.json"))
      return Receipt(bundle: "bundle", files: files, optimization: result)
    }
  }

  static func apply(
    bundle: URL, username: String = "admin", application: String? = nil,
    compress: Bool = true, profile: XcodeBuildProfile? = nil, journal: ExecutionJournal
  ) throws -> Details {
    guard username.range(of: #"\A[a-z][a-z0-9_-]{0,30}\z"#, options: .regularExpression) != nil
    else {
      throw MisoError.invalid("Invalid compression account")
    }
    let image = bundle.appendingPathComponent("disk.img")
    var compression: TransparentCompression.Receipt?
    var cleanedPaths: [String] = []
    var systemPolicy: OfflineSystemPolicy.Receipt?
    if (compress && (profile?.transparentCompression ?? true)) || profile?.cleanup == true
      || profile?.system.isEmpty == false
    {
      let mounted = try DiskImageSession(image: image, readOnly: false, journal: journal)
      compression = try mounted.withAttachment { session in
        let main = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal,
          name: "optimize-data", readOnly: false)
        if let policy = profile?.system, !policy.isEmpty {
          systemPolicy = try BuildProgress.run("Configure optional system services and settings") {
            let system = try ImageMounts.mount(
              main.volume(role: "System"), session: session, journal: journal,
              name: "policy-system", readOnly: true)
            let preboot = try ImageMounts.mount(
              main.volume(role: "Preboot"), session: session, journal: journal,
              name: "policy-preboot", readOnly: policy.settings["spotlightIndexing"] == nil)
            let account = try BaseImageStage.Account(username, data: data)
            let services =
              try policy.resolvedServices.isEmpty
              ? [:]
              : OfflineSystemPolicy.cryptexInventory(
                preboot: preboot, uid: account.uid, journal: journal)
            return try OfflineSystemPolicy.apply(
              policy, system: system, data: data, preboot: preboot,
              account: account, cancellation: journal.cancellation, additionalServices: services)
          }
        }
        var result: TransparentCompression.Receipt?
        if compress && (profile?.transparentCompression ?? true) {
          result = try BuildProgress.run("Compress installed files") {
            try journal.measure("compressionSeconds") {
              try TransparentCompression.run(
                data: data, roots: roots(username: username),
                workspace: journal.output, cancellation: journal.cancellation)
            }
          }
        }
        if profile?.cleanup == true {
          try BuildProgress.run("Clean developer download and build caches") {
            let account = try BaseImageStage.Account(username, data: data)
            for path in [
              "Library/Caches/Homebrew", "Library/Caches/npm",
              "Library/Caches/org.swift.swiftpm", "Library/Developer/Xcode/DerivedData",
              ".android/cache",
            ] {
              let relative = "Users/\(username)/" + path
              if try GuestCleanup.removeDirectory(
                relative, volume: data,
                uid: account.uid, gid: account.gid, cancellation: journal.cancellation) > 0
              {
                cleanedPaths.append(relative)
              }
            }
          }
        }
        return result
      }
    }
    let detached = try DiskImageSession(image: image, readOnly: false, journal: journal)
    var compaction: APFSCompaction.Receipt?
    if profile?.sparsify ?? true {
      compaction = try BuildProgress.run("Reclaim APFS free space and punch sparse holes") {
        try journal.measure("compactionSeconds") {
          try APFSCompaction.run(detached, cancellation: journal.cancellation)
        }
      }
    }
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment { session in
      for container in try session.containers() {
        let device = try APFSIdentity.rawVolume(container.stores[0].device)
        try journal.run(
          "verify-compacted-filesystem",
          NativeCommand(
            "/sbin/fsck_apfs", arguments: ["-n", "-s", device], timeout: 900))
      }
      if let application {
        let main = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal,
          name: "optimize-audit", readOnly: true)
        let app = try data.directory(application).url
        let modified =
          profile?.trimIntel == true
          || (profile.map { Set($0.platforms) != Set(XcodeConfiguration.Platform.allCases) }
            ?? false)
        if modified {
          try AppleCode.validate(
            app.appendingPathComponent("Contents/MacOS/Xcode"), scope: .executable)
        } else {
          try AppleCode.validate(app)
        }
        let signatureArguments =
          ["--verify", "--deep", "--strict"]
          + (modified ? ["--ignore-resources"] : []) + [app.path]
        try journal.run(
          "verify-compressed-xcode",
          NativeCommand(
            .codesign,
            arguments: signatureArguments, timeout: 900))
      }
    }
    let details = Details(
      compression: compression, compaction: compaction, cleanedPaths: cleanedPaths,
      systemPolicy: systemPolicy)
    try journal.setMetadata("optimization", value: details)
    return details
  }

  static func roots(username: String) -> [String] {
    [
      "Applications", "Library/Developer", "opt/homebrew/Cellar", "opt/homebrew/Caskroom",
      "usr/local",
      "Users/\(username)/.rbenv/versions", "Users/\(username)/.local/share/mise/installs",
      "Users/\(username)/flutter", "Users/\(username)/.pub-cache",
      "Users/\(username)/Library/Android",
      "Users/\(username)/android-sdk",
    ]
  }
}

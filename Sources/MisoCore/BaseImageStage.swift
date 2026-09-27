import Darwin
import Foundation

enum BaseImageStage {
  enum Layer { case base, xcode }

  struct Account: Sendable {
    let username: String
    let uid: UInt32
    let gid: UInt32

    init(_ username: String, data: GuestVolume) throws {
      guard username.range(of: #"\A[a-z][a-z0-9_-]{0,30}\z"#, options: .regularExpression) != nil
      else { throw MisoError.invalid("Invalid target account name") }
      let account = try data.plist("private/var/db/dslocal/nodes/Default/users/\(username).plist")
      guard let uidValues = account["uid"] as? [String], uidValues.count == 1,
        let uid = UInt32(uidValues[0]), (501...60_000).contains(uid),
        let gidValues = account["gid"] as? [String], gidValues.count == 1,
        let gid = UInt32(gidValues[0]), (20...60_000).contains(gid),
        account["home"] as? [String] == ["/Users/" + username]
      else { throw MisoError.invalid("Unexpected target account identity") }
      self.username = username
      self.uid = uid
      self.gid = gid
    }
  }

  static func run<T: Encodable>(
    source: URL, output: URL, operation: String, layer: Layer = .base,
    cancellation: CancellationToken?,
    body: (URL, MacOSRelease, ExecutionJournal) throws -> T
  ) throws -> BaseStageReceipt<T> {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Base construction requires administrator privileges")
    }
    _ = try APFSPrivate.requireHost()
    _ = try GuestVolume(source)
    let manifestURL = source.appendingPathComponent("manifest.json")
    let sourceManifest = try Artifacts.record(manifestURL, relativeTo: source)
    guard
      var manifest = try JSONSerialization.jsonObject(
        with: SafeFile.read(manifestURL, limit: 1 << 20)) as? [String: Any],
      manifest["construction_vm_started"] as? Bool == false,
      manifest["runtime_verified"] as? Bool == false,
      let targetFields = manifest["target"] as? [String: String],
      let version = targetFields["version"], let build = targetFields["build"]
    else { throw MisoError.invalid("A never-booted native source bundle is required") }
    try advanceManifest(&manifest, operation: operation, layer: layer)
    let target = try RestoreProfile.select(.init(version: version, build: build)).release
    let verificationStarted = ProcessInfo.processInfo.systemUptime
    let original = try ImageBundle.verify(source)
    let initialVerificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStarted
    let journal = try ExecutionJournal(
      output: output, operation: operation, cancellation: cancellation)
    return try journal.perform {
      try journal.setMetadata("target", value: target)
      try journal.setMetadata("initialSourceVerificationSeconds", value: initialVerificationSeconds)
      let sourceSession = try DiskImageSession(
        image: source.appendingPathComponent("disk.img"), readOnly: true, journal: journal)
      try sourceSession.requireDetached()
      let bundle = output.appendingPathComponent("bundle")
      try SafeFile.makeDirectory(bundle)
      for name in ImageBundle.requiredFiles.sorted() {
        try Artifacts.clone(
          source.appendingPathComponent(name), to: bundle.appendingPathComponent(name))
      }
      let details = try journal.measure("stageSeconds") { try body(bundle, target, journal) }
      try sourceSession.requireDetached()
      let sourceAfter = try journal.measure("finalSourceVerificationSeconds") {
        try ImageBundle.verify(source)
      }
      guard sourceAfter.files == original.files,
        try Artifacts.record(manifestURL, relativeTo: source) == sourceManifest
      else { throw MisoError.invalid("Base source changed during construction") }
      let files = try journal.measure("outputHashingSeconds") {
        try ImageBundle.requiredFiles.sorted().map {
          try Artifacts.record(bundle.appendingPathComponent($0), relativeTo: bundle)
        }
      }
      for file in files where file.path != "disk.img" {
        guard original.files.contains(file) else {
          throw MisoError.invalid("Base stage changed machine identity")
        }
      }
      manifest["files"] = try JSONSerialization.jsonObject(with: JSON.encode(files))
      manifest["runtime_verified"] = false
      manifest["cross_mac_verified"] = false
      try SafeFile.writeNew(
        JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]),
        to: bundle.appendingPathComponent("manifest.json"))
      try journal.measure("outputVerificationSeconds") { try ImageBundle.verify(bundle) }
      return BaseStageReceipt(
        target: target, sourceManifest: sourceManifest, files: files,
        details: details, originalsUnchanged: true,
        baseComplete: manifest["base_complete"] as? Bool == true,
        runtimeVerified: false, vmStarted: false)
    }
  }

  static func advanceManifest(
    _ manifest: inout [String: Any], operation: String, layer: Layer
  ) throws {
    let key: String
    switch layer {
    case .base:
      guard manifest["xcode_stages"] == nil else {
        throw MisoError.invalid("Base stages cannot replace an Xcode layer")
      }
      manifest["base_complete"] = false
      key = "base_stages"
    case .xcode:
      guard manifest["base_complete"] as? Bool == true,
        manifest["xcode_complete"] as? Bool != true, operation.hasPrefix("xcode-")
      else { throw MisoError.invalid("Xcode construction requires a complete Base source") }
      manifest["xcode_complete"] = false
      key = "xcode_stages"
    }
    var stages = manifest[key] as? [String] ?? []
    guard !stages.contains(operation) else {
      throw MisoError.invalid("Image stage was already applied: \(operation)")
    }
    stages.append(operation)
    manifest[key] = stages
  }

  static func mainContainer(_ session: DiskImageSession) throws -> APFSTopology.Container {
    let matches = try session.containers().filter { $0.volumes.contains { $0.roles == ["System"] } }
    guard matches.count == 1 else { throw MisoError.invalid("Ambiguous System container") }
    return matches[0]
  }
}

public struct BaseStageReceipt<Details: Encodable>: Encodable {
  public let target: MacOSRelease
  public let sourceManifest: ImageBundle.FileRecord
  public let files: [ImageBundle.FileRecord]
  public let details: Details
  public let originalsUnchanged: Bool
  public let baseComplete: Bool
  public let runtimeVerified: Bool
  public let vmStarted: Bool
}

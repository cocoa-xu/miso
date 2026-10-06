import Darwin
import Foundation

@MainActor
public enum BaseParentInputs {
  public struct Receipt: Codable {
    let schemaVersion: Int
    let sourceManifest: ImageBundle.FileRecord
    let boot: BaseBootSecurity.Boot
    let blobs: [String: ImageBundle.FileRecord]
    let originalsUnchanged: Bool
    let vmStarted: Bool
  }

  public static func run(
    source: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Preparing Base parent inputs requires administrator privileges")
    }
    _ = try APFSPrivate.requireHost()
    let volume = try GuestVolume(source)
    let manifestURL = try volume.path("manifest.json")
    let manifest = try SafeFile.read(manifestURL, limit: 1 << 20)
    guard let fields = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
      let release = fields["target"] as? [String: String],
      let version = release["version"], let build = release["build"],
      let groupText = fields["volume_group_uuid"] as? String,
      let group = UUID(uuidString: groupText),
      let ecidText = fields["ecid"] as? String, let ecid = UInt64(ecidText)
    else { throw MisoError.invalid("Missing Vanilla parent identity") }
    let target = MacOSRelease(version: version, build: build)
    try BasePipeline.requireVanilla(manifest, target: target)
    _ = try RestoreProfile.select(target)
    _ = try VirtualHardware.validateBundle(source, allowUnavailableHost: true)
    let original = try ImageBundle.snapshot(source)
    let sourceManifest = try Artifacts.record(manifestURL, relativeTo: source)
    let journal = try ExecutionJournal(
      output: output, operation: "prepare-base-parent", cancellation: cancellation)
    return try journal.perform {
      let session = try DiskImageSession(
        image: volume.path("disk.img"), readOnly: true, journal: journal)
      let recovered = try BuildProgress.run("Recover Base boot inputs from Vanilla") {
        try session.withAttachment {
          session -> (BaseBootSecurity.Boot, [String: ImageBundle.FileRecord]) in
          let mounts = try BaseBootSecurity.mounts(session, journal: journal, readOnly: true)
          let main = try BaseImageStage.mainContainer(session)
          let system = try ImageMounts.mount(
            main.volume(role: "System"), session: session, journal: journal,
            name: "parent-system", readOnly: true)
          let systemVersion = try system.plist("System/Library/CoreServices/SystemVersion.plist")
          guard systemVersion["ProductVersion"] as? String == target.version,
            systemVersion["ProductBuildVersion"] as? String == target.build
          else { throw MisoError.invalid("Parent System version differs from its manifest") }
          var records: [String: ImageBundle.FileRecord] = [:]
          func read(_ path: String, limit: Int = 4 << 20) throws -> Data {
            try journal.cancellation.check()
            let url = try BootInstallation.destination(path, mounts: mounts)
            let data = try SafeFile.read(url, limit: limit)
            records[path] = .init(
              path: path, bytes: UInt64(data.count), sha256: SafeFile.sha256(data))
            return data
          }
          let root = "Preboot/" + group.uuidString
          let active = try read(root + "/boot/active", limit: 128)
          let nsih = String(decoding: active, as: UTF8.self)
          guard nsih.range(of: #"\A[0-9A-F]{96}\z"#, options: .regularExpression) != nil else {
            throw MisoError.invalid("Invalid parent active boot manifest")
          }
          var macPolicy: Data?
          for identifier in [group, BootTree.recoveryIdentifier(group)] {
            let prefix = identifier.uuidString + "/LocalPolicy"
            let directory = try mounts["iSCPreboot"]!.directory(prefix).url
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard (1...8).contains(names.count) else {
              throw MisoError.invalid("Unexpected parent local policy count")
            }
            for name in names.sorted() {
              guard name.hasSuffix(".img4") else {
                throw MisoError.invalid("Unexpected parent local policy file")
              }
              let policy = try read("iSCPreboot/" + prefix + "/" + name, limit: 1 << 20)
              if identifier == group, !name.hasSuffix(".recovery.img4") {
                guard macPolicy == nil else { throw MisoError.invalid("Ambiguous parent policy") }
                macPolicy = policy
              }
            }
          }
          guard let macPolicy else { throw MisoError.invalid("Missing parent macOS policy") }
          let policyFields = try Image4Trust.fields(macPolicy)
          guard let encoded = try Image4.manifestProperties(policyFields[2].content)["MANP"] else {
            throw MisoError.invalid("Missing parent local policy properties")
          }
          let properties = try Image4.properties(encoded)
          try LocalPolicy.validate(properties, mode: .standard)
          var uuid = group.uuid
          guard properties["ECID"] == DER.integer(ecid),
            properties["vuid"] == DER.encode(4, withUnsafeBytes(of: &uuid) { Data($0) }),
            let nsihValue = properties["nsih"], let spihValue = properties["spih"],
            try SafeFile.hex(DER.one(nsihValue, tag: 4).content).uppercased() == nsih
          else { throw MisoError.invalid("Parent local policy identity differs from its manifest") }
          let spih = try SafeFile.hex(DER.one(spihValue, tag: 4).content).uppercased()
          let ticket = try read(root + "/restore/apticket.vma2macosap.im4m", limit: 1 << 20)
          _ = try read(root + "/cryptex1/current/apticket.vma2macosap.im4m", limit: 1 << 20)
          let cache = try RestoreInspection.plist(
            read(root + "/restore/usr/standalone/bootcaches.plist"))
          guard let bless = cache["bless2"] as? [String: Any],
            let objects = bless["BootObjects"] as? [String: [String: Any]]
          else { throw MisoError.invalid("Missing parent boot object map") }
          var kernel: Data?
          for (name, type) in BootPersonalization.objects {
            guard let destination = objects[name]?["DestinationPath"] as? String,
              destination.hasPrefix("./")
            else { throw MisoError.invalid("Missing parent boot object: \(name)") }
            let relative = try SafeFile.relativePath(String(destination.dropFirst(2)))
            let image = try read(root + "/boot/" + nsih + "/" + relative, limit: 128 << 20)
            let payload = try Image4Trust.fields(image)[1].encoded
            try Image4.verifyDigest(payload: payload, ticket: ticket, type: type)
            try Image4Trust.authenticate(
              Image4.stitch(payload: payload, ticket: ticket), type: type, decoder: .globalFirmware)
            if name == "KernelCache" { kernel = payload }
          }
          for (_, _, name) in BootPersonalization.cryptexObjects where !name.hasSuffix(".dmg") {
            _ = try read(root + "/cryptex1/current/" + name)
          }
          guard let kernel else { throw MisoError.invalid("Missing parent kernelcache") }
          let extracted = try KernelCollection.extract(kernel, journal: journal)
          func blob(_ name: String) throws -> Data {
            try SafeFile.read(
              Artifacts.resolve(extracted.blobs[name]!, under: output), limit: 1 << 20)
          }
          let key = try LocalPolicy.key(blob("key"), certificates: blob("certificates"))
          guard try LocalPolicy.verify(macPolicy, key: key.publicKey),
            policyFields[1].encoded == (try blob("payload"))
          else { throw MisoError.invalid("Recovered signing material differs from parent policy") }
          try FileManager.default.removeItem(
            at: output.appendingPathComponent(extracted.kernel.path))
          let boot = BaseBootSecurity.Boot(
            target: target, volumeGroup: group, nsih: nsih, spih: spih,
            files: records.values.sorted { $0.path < $1.path })
          return (boot, extracted.blobs)
        }
      }
      guard try ImageBundle.snapshot(source) == original,
        try Artifacts.record(manifestURL, relativeTo: source) == sourceManifest
      else { throw MisoError.invalid("Vanilla parent changed while recovering Base inputs") }
      return Receipt(
        schemaVersion: 1, sourceManifest: sourceManifest, boot: recovered.0, blobs: recovered.1,
        originalsUnchanged: true, vmStarted: false)
    }
  }
}

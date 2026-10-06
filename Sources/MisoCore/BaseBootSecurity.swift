import CryptoKit
import Foundation

@MainActor
enum BaseBootSecurity {
  struct Boot: Codable, Sendable {
    let target: MacOSRelease
    let volumeGroup: UUID
    let nsih: String
    let spih: String
    let files: [ImageBundle.FileRecord]
  }

  struct Inputs {
    let boot: Boot
    let bootRoot: URL
    let materialRoot: URL
    let blobs: [String: ImageBundle.FileRecord]
    let bootJournal: ImageBundle.FileRecord
    let materialJournal: ImageBundle.FileRecord

    init(boot: URL, material: URL, target: MacOSRelease) throws {
      func result<T: Decodable>(_ type: T.Type, root: URL, operation: String) throws -> T {
        let journal = try JSON.read(
          ExecutionJournal.Record.self, from: root.appendingPathComponent("journal.json"))
        guard journal.status == .complete, journal.operation == operation, !journal.vmStarted,
          let result = journal.result
        else {
          throw MisoError.invalid("Expected completed native boot inputs")
        }
        return try JSONDecoder().decode(type, from: JSON.encode(result))
      }
      bootRoot = boot
      materialRoot = material
      bootJournal = try Artifacts.record(
        boot.appendingPathComponent("journal.json"), relativeTo: boot)
      materialJournal = try Artifacts.record(
        material.appendingPathComponent("journal.json"), relativeTo: material)
      if boot.standardized == material.standardized {
        let recovered = try result(
          BaseParentInputs.Receipt.self, root: boot, operation: "prepare-base-parent")
        guard recovered.schemaVersion == 1, recovered.boot.target == target,
          !recovered.vmStarted, recovered.originalsUnchanged,
          Set(recovered.blobs.keys) == ["key", "certificates", "payload"]
        else { throw MisoError.invalid("Invalid recovered Base parent inputs") }
        self.boot = recovered.boot
        blobs = recovered.blobs
      } else {
        let original = try result(
          BootPersonalization.Receipt.self, root: boot, operation: "personalize-boot")
        let policyMaterial = try result(
          KernelCollection.Receipt.self, root: material, operation: "prepare-policy-material")
        guard original.profile.release == target, policyMaterial.profile == original.profile,
          policyMaterial.preparedJournal == original.preparedJournal,
          materialJournal == original.materialJournal
        else {
          throw MisoError.invalid("Base security material does not belong to target boot inputs")
        }
        self.boot = Boot(
          target: target, volumeGroup: original.volumeGroup, nsih: original.nsih,
          spih: original.spih, files: original.files)
        blobs = policyMaterial.blobs
      }
      guard Set(self.boot.files.map(\.path)).count == self.boot.files.count else {
        throw MisoError.invalid("Duplicate boot records")
      }
      for record in self.boot.files {
        _ = try SafeFile.relativePath(record.path)
        try SafeFile.validateSHA256(record.sha256)
      }
    }

    func blob(_ name: String) throws -> Data {
      guard let record = blobs[name] else {
        throw MisoError.invalid("Missing policy material")
      }
      return try SafeFile.read(Artifacts.resolve(record, under: materialRoot), limit: 1 << 20)
    }

    func verifyJournal() throws {
      guard
        try Artifacts.record(bootRoot.appendingPathComponent("journal.json"), relativeTo: bootRoot)
          == bootJournal,
        try Artifacts.record(
          materialRoot.appendingPathComponent("journal.json"), relativeTo: materialRoot)
          == materialJournal
      else {
        throw MisoError.invalid("Base security input journal changed")
      }
    }
  }

  struct Receipt: Codable {
    let nsih: String
    let spih: String
    let files: [ImageBundle.FileRecord]
    let retained: [ImageBundle.FileRecord]
    let authenticatedRootDisabled: Bool
  }

  static func mounts(_ session: DiskImageSession, journal: ExecutionJournal, readOnly: Bool) throws
    -> [String: GuestVolume]
  {
    let containers = try session.containers()
    let isc = containers.filter {
      Set($0.volumes.flatMap(\.roles)) == VolumeConstruction.expectedRoles[.isc]
    }
    guard isc.count == 1 else { throw MisoError.invalid("Ambiguous iSC container") }
    let main = try BaseImageStage.mainContainer(session)
    return [
      "Preboot": try ImageMounts.mount(
        main.volume(role: "Preboot"), session: session, journal: journal, name: "base-preboot",
        readOnly: readOnly),
      "iSCPreboot": try ImageMounts.mount(
        isc[0].volume(role: "Preboot"), session: session, journal: journal, name: "base-isc",
        readOnly: readOnly),
    ]
  }

  static func apply(_ inputs: Inputs, mounts: [String: GuestVolume], journal: ExecutionJournal)
    throws -> Receipt
  {
    let group = inputs.boot.volumeGroup.uuidString
    let root = "Preboot/" + group
    func read(_ path: String, limit: Int = 128 << 20) throws -> Data {
      let matches = inputs.boot.files.filter { $0.path == path }
      guard matches.count == 1 else { throw MisoError.invalid("Missing bound boot input: \(path)") }
      return try readBound(matches[0], mounts: mounts, limit: limit)
    }
    let activePath = root + "/boot/active"
    let active = try read(activePath, limit: 128)
    guard active == Data(inputs.boot.nsih.utf8) else {
      throw MisoError.invalid("Unexpected active boot manifest")
    }
    let ticket = try read(root + "/restore/apticket.vma2macosap.im4m", limit: 1 << 20)
    let cryptexTicket = try read(
      root + "/cryptex1/current/apticket.vma2macosap.im4m", limit: 1 << 20)
    let nsih = BootPersonalization.hex384(ticket)
    let spih = BootPersonalization.hex384(cryptexTicket)
    guard nsih != inputs.boot.nsih, spih != inputs.boot.spih else {
      throw MisoError.invalid("Expected personalized source boot policy")
    }
    let policies = inputs.boot.files.filter {
      $0.path.hasPrefix("iSCPreboot/") && $0.path.contains("/LocalPolicy/")
    }
    let candidates = policies.filter { !$0.path.hasSuffix(".recovery.img4") }
    guard candidates.count == 1 else { throw MisoError.invalid("Ambiguous macOS local policy") }
    let policyPath = candidates[0].path
    let original = try read(policyPath, limit: 1 << 20)
    let fields = try Image4Trust.fields(original)
    guard let encoded = try Image4.manifestProperties(fields[2].content)["MANP"] else {
      throw MisoError.invalid("Missing policy properties")
    }
    var properties = try Image4.properties(encoded)
    try LocalPolicy.validate(properties, mode: .standard)
    guard let nsihValue = properties["nsih"], let spihValue = properties["spih"],
      try SafeFile.hex(DER.one(nsihValue, tag: 4).content).uppercased() == inputs.boot.nsih,
      try SafeFile.hex(DER.one(spihValue, tag: 4).content).uppercased() == inputs.boot.spih
    else { throw MisoError.invalid("Source policy ticket binding differs") }
    let chain = try inputs.blob("certificates")
    let key = try LocalPolicy.key(inputs.blob("key"), certificates: chain)
    guard try LocalPolicy.verify(original, key: key.publicKey),
      fields[1].encoded == (try inputs.blob("payload"))
    else {
      throw MisoError.invalid("Source policy signing identity differs")
    }
    let retained = try inputs.boot.files.filter {
      ($0.path.hasPrefix("Preboot/") || $0.path.hasPrefix("iSCPreboot/")) && $0.path != activePath
        && $0.path != policyPath
    }.map { record in
      let actual = try BootInstallation.destination(record.path, mounts: mounts)
      guard try SafeFile.sha256(actual) == record.sha256 else {
        throw MisoError.invalid("Retained boot input differs")
      }
      return record
    }
    let cacheData = try read(root + "/restore/usr/standalone/bootcaches.plist", limit: 4 << 20)
    guard let bless = try RestoreInspection.plist(cacheData)["bless2"] as? [String: Any],
      let objects = bless["BootObjects"] as? [String: [String: Any]]
    else { throw MisoError.invalid("Missing boot object map") }
    var replacement: [String: Data] = [:]
    for (name, type) in BootPersonalization.objects {
      guard let destination = objects[name]?["DestinationPath"] as? String,
        destination.hasPrefix("./")
      else { throw MisoError.invalid("Missing boot object destination") }
      let relative = try SafeFile.relativePath(String(destination.dropFirst(2)))
      let image = try read(root + "/boot/" + inputs.boot.nsih + "/" + relative)
      let payload = try Image4Trust.fields(image)[1].encoded
      try Image4.verifyDigest(payload: payload, ticket: ticket, type: type)
      let global = try Image4.stitch(payload: payload, ticket: ticket)
      try Image4Trust.authenticate(global, type: type, decoder: .globalFirmware)
      replacement[root + "/boot/" + nsih + "/" + relative] = global
    }
    for (_, type, name) in BootPersonalization.cryptexObjects {
      let path = root + "/cryptex1/current/" + name
      let url = try BootInstallation.destination(path, mounts: mounts)
      let digest = try BootTree.hash384(url, cancellation: journal.cancellation)
      guard try digest == Image4.manifestValue(cryptexTicket, section: type, name: "DGST") else {
        throw MisoError.invalid("Global Cryptex digest differs")
      }
      if !name.hasSuffix(".dmg") {
        let global = try Image4.stitch(
          payload: SafeFile.read(url, limit: 64 << 20), ticket: cryptexTicket)
        try Image4Trust.authenticate(global, type: type, decoder: .globalCryptex)
      }
    }
    properties["nsih"] = DER.encode(4, Data(SHA384.hash(data: ticket)))
    properties["spih"] = DER.encode(4, Data(SHA384.hash(data: cryptexTicket)))
    properties["sip0"] = DER.integer(127)
    for name in ["sip2", "sip3", "smb0", "smb1"] { properties[name] = DER.encode(1, Data([0xFF])) }
    replacement[policyPath] = try LocalPolicy.sign(
      properties: properties, payload: inputs.blob("payload"), key: key, chain: chain, mode: .base
    ).image
    replacement[activePath] = Data(nsih.utf8)
    var records: [ImageBundle.FileRecord] = []
    for (path, bytes) in replacement.sorted(by: { $0.key < $1.key }) {
      let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
      guard let volume = mounts[parts[0]] else { throw MisoError.invalid("Unknown boot volume") }
      if path != activePath && path != policyPath {
        guard !(try volume.contains(parts[1])) else {
          throw MisoError.invalid("Global boot destination exists")
        }
      }
      try volume.makeDirectories((parts[1] as NSString).deletingLastPathComponent)
      try volume.write(parts[1], data: bytes)
      records.append(.init(path: path, bytes: UInt64(bytes.count), sha256: SafeFile.sha256(bytes)))
    }
    let receipt = Receipt(
      nsih: nsih, spih: spih, files: records, retained: retained, authenticatedRootDisabled: false)
    try verify(receipt, mounts: mounts)
    try inputs.verifyJournal()
    return receipt
  }

  static func verify(_ receipt: Receipt, mounts: [String: GuestVolume]) throws {
    for record in receipt.files + receipt.retained {
      let path = try BootInstallation.destination(record.path, mounts: mounts)
      guard try SafeFile.sha256(path) == record.sha256 else {
        throw MisoError.invalid("Base boot readback differs: \(record.path)")
      }
    }
  }

  static func preflight(_ inputs: Inputs, mounts: [String: GuestVolume]) throws {
    let suffixes = [
      "/boot/active", "/restore/apticket.vma2macosap.im4m",
      "/cryptex1/current/apticket.vma2macosap.im4m", "/restore/usr/standalone/bootcaches.plist",
    ]
    let records = inputs.boot.files.filter { record in
      suffixes.contains(where: { record.path.hasSuffix($0) })
        || record.path.contains("/LocalPolicy/")
    }
    guard records.count >= suffixes.count + 2 else {
      throw MisoError.invalid("Missing boot policy inputs")
    }
    for record in records { _ = try readBound(record, mounts: mounts, limit: 4 << 20) }
    _ = try LocalPolicy.key(inputs.blob("key"), certificates: inputs.blob("certificates"))
    _ = try Image4.payloadFields(inputs.blob("payload"))
  }

  nonisolated static func readBound(
    _ record: ImageBundle.FileRecord, mounts: [String: GuestVolume], limit: Int
  ) throws -> Data {
    let actual = try BootInstallation.destination(record.path, mounts: mounts)
    let bytes = try SafeFile.read(actual, limit: limit)
    guard UInt64(bytes.count) == record.bytes, SafeFile.sha256(bytes) == record.sha256 else {
      throw MisoError.invalid("Candidate boot input differs: \(record.path)")
    }
    return bytes
  }
}

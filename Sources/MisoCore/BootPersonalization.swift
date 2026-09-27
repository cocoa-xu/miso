import CryptoKit
import Darwin
import Foundation
import Security

@MainActor
public enum BootPersonalization {
  public struct Receipt: Codable, Sendable {
    public let profile: RestoreProfile
    public let preparedJournal: ImageBundle.FileRecord
    public let sourceJournal: ImageBundle.FileRecord
    public let materialJournal: ImageBundle.FileRecord
    public let volumeGroup: UUID
    public let recovery: UUID
    public let nsih: String
    public let spih: String
    public let lpnh: String
    public let ronh: String
    public let auxiliary: ImageBundle.FileRecord
    public let identity: [ImageBundle.FileRecord]
    public let files: [ImageBundle.FileRecord]
    public let directories: [String]
    let links: [BootTree.Link]
    public let requiredClone: String
  }

  static let objects = [
    ("Ap,BaseSystemTrustCache", "bstc"), ("BaseSystemVolume", "csys"), ("DeviceTree", "dtre"),
    ("iBoot", "ibot"), ("KernelCache", "krnl"), ("StaticTrustCache", "trst"),
    ("SystemVolume", "isys"),
  ]
  static let cryptexObjects = [
    ("SystemOS", "csos", "os.dmg"), ("SystemVolume", "cssy", "os.dmg.root_hash"),
    ("SystemTrustCache", "trcs", "os.dmg.trustcache"), ("AppOS", "caos", "app.dmg"),
    ("AppVolume", "casy", "app.dmg.root_hash"), ("AppTrustCache", "trca", "app.dmg.trustcache"),
  ]

  public static func run(
    prepared: URL, toolsStage: URL, materialStage: URL, output: URL,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    _ = try APFSPrivate.requireHost()
    let inputs = try PreparedInputs(prepared)
    let source = try ConstructedDisk<ToolsConstruction.Receipt>(
      directory: toolsStage, operation: "install-clt", inputs: inputs, cancellation: cancellation)
    let materialJournal = try JSON.read(
      ExecutionJournal.Record.self, from: materialStage.appendingPathComponent("journal.json"))
    guard materialJournal.status == .complete,
      materialJournal.operation == "prepare-policy-material", !materialJournal.vmStarted,
      let value = materialJournal.result
    else { throw MisoError.invalid("Completed native policy material is required") }
    let material = try JSONDecoder().decode(KernelCollection.Receipt.self, from: JSON.encode(value))
    guard material.profile == inputs.receipt.profile,
      material.preparedJournal == inputs.journalRecord
    else {
      throw MisoError.invalid("Policy material belongs to different prepared inputs")
    }
    var blobs: [String: Data] = [:]
    for name in ["key", "certificates", "payload"] {
      guard let file = material.blobs[name] else {
        throw MisoError.invalid("Missing policy material")
      }
      blobs[name] = try SafeFile.read(Artifacts.resolve(file, under: materialStage), limit: 1 << 20)
    }
    guard let privateKey = blobs["key"], let chain = blobs["certificates"],
      let policyPayload = blobs["payload"]
    else {
      throw MisoError.invalid("Incomplete policy material")
    }
    let key = try LocalPolicy.key(privateKey, certificates: chain)
    let journal = try ExecutionJournal(
      output: output, operation: "personalize-boot", cancellation: cancellation)
    do {
      let profile = inputs.receipt.profile
      let group = source.receipt.volumes.volumeGroup
      let recovery = BootTree.recoveryIdentifier(group)
      guard let ecid = UInt64(inputs.receipt.ecid), ecid > 0 else {
        throw MisoError.invalid("Invalid prepared ECID")
      }
      try journal.setMetadata("target", value: profile.release)
      try journal.setMetadata("preparedJournal", value: inputs.journalRecord)
      try journal.setMetadata("sourceJournal", value: source.journalRecord)
      let tree = try BootTree(journal: journal)
      let manifest = try RestoreInspection.plist(
        SafeFile.read(inputs.requireInput("BuildManifest.plist"), limit: 64 << 20))
      let erase = try RestoreTickets.identity(
        manifest, profile: profile, variant: profile.restoreVariant)
      let macos = try RestoreTickets.identity(manifest, profile: profile, variant: "macOS Customer")
      let caches = try RestoreInspection.plist(
        SafeFile.read(inputs.requireInput("usr/standalone/bootcaches.plist"), limit: 4 << 20))
      guard
        let cache = (caches["bless2"] as? [String: Any])?["BootObjects"] as? [String: [String: Any]]
      else {
        throw MisoError.invalid("Missing restore boot object destinations")
      }
      let baseSystem = try inputs.file("BaseSystem", cancellation: cancellation)
      let cryptexSystem = try inputs.file("Cryptex1,SystemOS", cancellation: cancellation)
      var generator: UInt64 = 0
      while generator == 0 { generator = try random(8).integer(at: 0, as: UInt64.self) }
      let nonces = try random(112)
      try SafeFile.writeNew(nonces, to: journal.output.appendingPathComponent("policy-nonces.bin"))
      try journal.setMetadata("generator", value: String(format: "0x%016llx", generator))
      var tickets: [RestoreTickets.Kind: Data] = [:]
      for kind in RestoreTickets.Kind.allCases {
        let identity = kind == .firmware || kind == .sfr ? erase : macos
        let request = try RestoreTickets.request(
          kind, identity: identity, ecid: ecid, generator: generator)
        let ticket = try await RestoreTickets.send(
          request, name: kind.rawValue, journal: journal, cryptex: kind == .cryptex)
        try RestoreTickets.verify(
          ticket, profile: profile, ecid: ecid, generator: generator, cryptex: kind == .cryptex)
        tickets[kind] = ticket
      }
      guard let macTicket = tickets[.macos], let cryptexTicket = tickets[.cryptex],
        let recoveryTicket = tickets[.sfr], let firmwareTicket = tickets[.firmware]
      else { throw MisoError.invalid("Incomplete restore tickets") }
      let nsih = hex384(macTicket)
      let spih = hex384(cryptexTicket)
      let sfr = hex384(recoveryTicket)
      let lpnh = hex384(nonces[16..<32])
      let ronh = hex384(nonces[64..<80])
      for (identity, ticket, volume, prefix) in [
        (macos, macTicket, group, "Preboot"), (erase, recoveryTicket, recovery, "SystemRecovery"),
      ] {
        let boot = prefix + "/" + volume.uuidString + "/boot/" + hex384(ticket)
        for (component, type) in objects {
          let payload = try Image4.retype(
            SafeFile.read(
              componentPath(component, identity: identity, inputs: inputs), limit: 128 << 20),
            type: type)
          try Image4.verifyDigest(payload: payload, ticket: ticket, type: type)
          guard var destination = cache[component]?["DestinationPath"] as? String else {
            throw MisoError.invalid("Missing boot object destination")
          }
          if destination.hasPrefix("./") { destination.removeFirst(2) }
          let image = try Image4.stitch(payload: payload, ticket: ticket)
          try Image4Trust.authenticate(image, type: type, decoder: .firmware)
          try tree.write(boot + "/" + SafeFile.relativePath(destination), image)
        }
        if prefix == "SystemRecovery" {
          try tree.plist(boot + "/BuildManifest.plist", ["BuildIdentities": [identity]])
          try tree.clone(baseSystem, boot + "/usr/standalone/firmware/arm64eBaseSystem.dmg")
        }
      }
      try tree.write("Preboot/" + group.uuidString + "/boot/active", Data(nsih.utf8))
      for name in ["SystemVersion.plist", "RestoreVersion.plist"] {
        try tree.clone(
          inputs.requireInput(name),
          "Preboot/" + group.uuidString + "/System/Library/CoreServices/" + name)
      }
      let cryptex = "Preboot/" + group.uuidString + "/cryptex1/current"
      for (name, type, filename) in cryptexObjects {
        let origin =
          try name == "SystemOS"
          ? cryptexSystem : componentPath("Cryptex1," + name, identity: macos, inputs: inputs)
        guard
          try BootTree.hash384(origin, cancellation: journal.cancellation)
            == Image4.manifestValue(cryptexTicket, section: type, name: "DGST")
        else {
          throw MisoError.invalid("Cryptex signed digest mismatch")
        }
        if !name.hasSuffix("OS") {
          let image = try Image4.stitch(
            payload: SafeFile.read(origin, limit: 32 << 20), ticket: cryptexTicket)
          try Image4Trust.authenticate(image, type: type, decoder: .firmware)
        }
        try tree.clone(origin, cryptex + "/" + filename)
      }
      for (directory, ticket, variant) in [
        ("Preboot/" + group.uuidString + "/restore", macTicket, "macOS Customer"),
        (cryptex, cryptexTicket, "cryptex1/macOS Customer"),
      ] {
        try tree.plist(directory + "/BuildManifest.plist", ["BuildIdentities": [macos]])
        try tree.write(
          directory + String(format: "/apticket.%@.%016llX.im4m", profile.deviceClass, ecid), ticket
        )
        try tree.clone(
          inputs.requireInput(
            "Firmware/Manifests/restore/" + variant + "/apticket." + profile.deviceClass + ".im4m"),
          directory + "/apticket." + profile.deviceClass + ".im4m")
        for name in ["SystemVersion.plist", "RestoreVersion.plist"] {
          try tree.clone(inputs.requireInput(name), directory + "/" + name)
        }
        try tree.clone(
          inputs.requireInput("usr/standalone/bootcaches.plist"),
          directory
            + (directory == cryptex ? "/bootcaches.plist" : "/usr/standalone/bootcaches.plist"))
      }
      for name in [
        "Cryptexes", "Cryptexes/OS", "Cryptexes/App", "Cryptexes/Incoming", "Cryptexes/Incoming/OS",
        "Cryptexes/Incoming/App",
      ] {
        try tree.directory("Preboot/" + name)
      }
      try tree.clone(
        baseSystem,
        "PairedRecovery/" + group.uuidString + "/usr/standalone/firmware/arm64eBaseSystem.dmg")
      for relative in ["SFR/current", "SystemRecovery/" + sfr] {
        let directory = "iSCPreboot/" + relative
        try tree.write(directory + "/apticket.der", recoveryTicket)
        try tree.clone(
          inputs.requireInput("usr/standalone/bootcaches.plist"), directory + "/bootcaches.plist")
        for name in ["SystemVersion.plist", "RestoreVersion.plist"] {
          try tree.clone(inputs.requireInput(name), directory + "/" + name)
        }
      }
      try await policies(
        tree: tree, profile: profile, ecid: ecid, group: group, recovery: recovery,
        macTicket: macTicket,
        cryptexTicket: cryptexTicket, recoveryTicket: recoveryTicket, nonces: nonces,
        payload: policyPayload,
        key: key, chain: chain, journal: journal)
      let restore = try DER.encode(
        0x30,
        DER.encode(0x16, Data("IM4R".utf8))
          + DER.encode(
            0x31,
            Image4.property(
              "BNCN", value: DER.encode(4, withUnsafeBytes(of: generator.littleEndian) { Data($0) })
            )))
      var firmware: [String: Data] = [:]
      for name in ["LLB", "AppleLogo"] {
        let payload = try SafeFile.read(
          componentPath(name, identity: erase, inputs: inputs), limit: 16 << 20)
        let type = String(decoding: try Image4.payloadFields(payload)[1].content, as: UTF8.self)
        try Image4.verifyDigest(payload: payload, ticket: firmwareTicket, type: type)
        let image = try Image4.stitch(payload: payload, ticket: firmwareTicket, restore: restore)
        try Image4Trust.authenticate(image, type: type, decoder: .firmware, nonce: true)
        firmware[name] = image
      }
      let identityDirectory = journal.output.appendingPathComponent("identity")
      try SafeFile.makeDirectory(identityDirectory)
      var identityRecords: [ImageBundle.FileRecord] = []
      for record in inputs.receipt.identity {
        let origin = try Artifacts.resolve(record, under: prepared)
        let destination = identityDirectory.appendingPathComponent(origin.lastPathComponent)
        try Artifacts.copy(
          origin, to: destination, maximumBytes: 64 << 20, cancellation: journal.cancellation)
        identityRecords.append(try Artifacts.record(destination, relativeTo: journal.output))
      }
      let identifier = try RestoreInspection.plist(
        SafeFile.read(
          identityDirectory.appendingPathComponent("machine-identifier.bin"), limit: 1 << 20))
      guard (identifier["ECID"] as? NSNumber)?.uint64Value == ecid,
        let llb = firmware["LLB"], let logo = firmware["AppleLogo"]
      else { throw MisoError.invalid("Identity or firmware mismatch") }
      let main = source.receipt.volumes.layout.partitions[1]
      let auxiliary = try AuxiliaryStorage.assemble(
        empty: SafeFile.read(
          identityDirectory.appendingPathComponent("aux-empty.bin"), limit: AuxiliaryStorage.size),
        llb: llb, appleLogo: logo, nonces: nonces, generator: generator,
        selection: .init(
          partitionType: main.type, partitionIdentifier: main.identifier, systemIdentifier: group),
        profile: profile)
      let auxiliaryPath = journal.output.appendingPathComponent("aux.bin")
      try SafeFile.writeNew(auxiliary, to: auxiliaryPath)
      let inventory = try tree.inventory(cancellation: journal.cancellation)
      let result = Receipt(
        profile: profile, preparedJournal: inputs.journalRecord,
        sourceJournal: source.journalRecord,
        materialJournal: try Artifacts.record(
          materialStage.appendingPathComponent("journal.json"), relativeTo: materialStage),
        volumeGroup: group, recovery: recovery, nsih: nsih, spih: spih, lpnh: lpnh, ronh: ronh,
        auxiliary: try Artifacts.record(auxiliaryPath, relativeTo: journal.output),
        identity: identityRecords,
        files: inventory.0, directories: inventory.1, links: inventory.2,
        requiredClone: cryptex + "/os.clone.dmg")
      try SafeFile.writeNew(
        JSON.encode(result), to: journal.output.appendingPathComponent("boot.json"))
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  static func componentPath(_ name: String, identity: [String: Any], inputs: PreparedInputs) throws
    -> URL
  {
    guard let components = identity["Manifest"] as? [String: [String: Any]],
      let info = components[name]?["Info"] as? [String: Any], let path = info["Path"] as? String
    else { throw MisoError.invalid("Missing boot component path") }
    return try inputs.requireInput(path)
  }

  static func policies(
    tree: BootTree, profile: RestoreProfile, ecid: UInt64, group: UUID, recovery: UUID,
    macTicket: Data, cryptexTicket: Data, recoveryTicket: Data, nonces: Data, payload: Data,
    key: P384.Signing.PrivateKey, chain: Data, journal: ExecutionJournal
  ) async throws {
    var properties = [
      "BORD": UInt64(profile.boardID), "CHIP": UInt64(profile.chipID), "ECID": ecid,
      "SDOM": UInt64(profile.securityDomain), "CEPO": UInt64(1),
    ].mapValues(DER.integer)
    for name in ["CPRO", "CSEC", "lobo"] { properties[name] = DER.encode(1, Data([0xFF])) }
    properties["lpnh"] = DER.encode(4, Data(SHA384.hash(data: nonces[16..<32])))
    properties["rpnh"] = DER.encode(4, Data(SHA384.hash(data: nonces[..<16])))
    properties["nsih"] = DER.encode(4, Data(SHA384.hash(data: macTicket)))
    var identifier = group.uuid
    properties["vuid"] = DER.encode(4, withUnsafeBytes(of: &identifier) { Data($0) })
    guard let manifest = try Image4.manifestProperties(macTicket)["MANP"],
      let love = try Image4.properties(manifest)["love"]
    else { throw MisoError.invalid("Missing policy version") }
    properties["love"] = love
    properties["kuid"] = DER.encode(4, Data(count: 16))
    let mac: [String: Data] = [
      "hrlp": DER.encode(1, Data([0xFF])),
      "spih": DER.encode(4, Data(SHA384.hash(data: cryptexTicket))), "stng": DER.integer(1),
    ]
    for (extra, suffix) in [
      (mac, ".img4"), (["rolp": DER.encode(1, Data([0xFF]))], ".recovery.img4"),
    ] {
      let signed = try LocalPolicy.sign(
        properties: properties.merging(extra) { _, new in new }, payload: payload, key: key,
        chain: chain)
      try tree.write(
        "iSCPreboot/" + group.uuidString + "/LocalPolicy/" + hex384(nonces[16..<32]) + suffix,
        signed.image)
    }
    let request = try RestoreTickets.recovery(
      profile: profile, ecid: ecid, payload: payload, ticket: recoveryTicket, nonces: nonces,
      volume: recovery)
    let ticket = try await RestoreTickets.send(request, name: "recovery-policy", journal: journal)
    try RestoreTickets.verify(ticket, profile: profile, ecid: ecid)
    var recoveryUUID = recovery.uuid
    let expected: [String: Data] = [
      "nsih": Data(SHA384.hash(data: recoveryTicket)),
      "ronh": Data(SHA384.hash(data: nonces[64..<80])),
      "vuid": withUnsafeBytes(of: &recoveryUUID) { Data($0) },
    ]
    for (name, value) in expected {
      guard try Image4.manifestValue(ticket, section: "MANP", name: name) == value else {
        throw MisoError.invalid("System Recovery policy binding mismatch")
      }
    }
    try Image4.verifyDigest(payload: payload, ticket: ticket, type: "lpol")
    let image = try Image4.stitch(payload: payload, ticket: ticket)
    try Image4Trust.authenticate(image, type: "lpol", decoder: .recoveryPolicy)
    let ronh = hex384(nonces[64..<80])
    try tree.write(
      "iSCPreboot/" + recovery.uuidString + "/LocalPolicy/" + ronh + ".recovery.img4", image)
    let link = try Artifacts.makeParents(for: "iSCPreboot/SystemRecovery/" + ronh, under: tree.root)
    guard symlink(hex384(recoveryTicket), link.path) == 0 else {
      throw MisoError.system("Create recovery policy link", errno)
    }
  }

  static func hex384(_ data: Data) -> String { SafeFile.hex(SHA384.hash(data: data)).uppercased() }

  static func random(_ count: Int) throws -> Data {
    var data = Data(count: count)
    guard
      data.withUnsafeMutableBytes({
        SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
      }) == errSecSuccess
    else {
      throw MisoError.invalid("Secure random bytes unavailable")
    }
    return data
  }
}

import CryptoKit
import Foundation

enum RestoreTickets {
  enum Kind: String, CaseIterable { case firmware, macos, cryptex, sfr }

  static let components: [Kind: [String]] = [
    .firmware: ["LLB", "AppleLogo"],
    .macos: [
      "Ap,BaseSystemTrustCache", "Ap,SystemVolumeCanonicalMetadata", "BaseSystemVolume",
      "DeviceTree", "KernelCache", "OS", "StaticTrustCache", "SystemVolume", "iBoot",
    ],
    .sfr: [
      "Ap,BaseSystemTrustCache", "Ap,SystemVolumeCanonicalMetadata", "Ap,rOSLogo1", "Ap,rOSLogo2",
      "AppleLogo", "BaseSystemVolume", "DeviceTree", "KernelCache", "LLB", "OS", "RecoveryMode",
      "RestoreDeviceTree", "RestoreKernelCache", "RestoreLogo", "RestoreRamDisk",
      "RestoreTrustCache", "StaticTrustCache", "SystemVolume", "iBEC", "iBSS", "iBoot",
    ],
    .cryptex: [
      "Cryptex1,AppOS", "Cryptex1,AppTrustCache", "Cryptex1,AppVolume", "Cryptex1,SystemOS",
      "Cryptex1,SystemTrustCache", "Cryptex1,SystemVolume",
    ],
  ]

  static func nonce(_ generator: UInt64) throws -> Data {
    guard generator > 0 else { throw MisoError.invalid("Invalid boot nonce generator") }
    var number = generator.littleEndian
    return Data(SHA384.hash(data: withUnsafeBytes(of: &number) { Data($0) })).prefix(32)
  }

  static func number(_ value: Any?) throws -> UInt64 {
    guard let string = value as? String,
      let result = UInt64(
        string.hasPrefix("0x") ? String(string.dropFirst(2)) : string,
        radix: string.hasPrefix("0x") ? 16 : 10)
    else { throw MisoError.invalid("Invalid restore identity integer") }
    return result
  }

  static func identity(_ manifest: [String: Any], profile: RestoreProfile, variant: String) throws
    -> [String: Any]
  {
    let candidates = (manifest["BuildIdentities"] as? [[String: Any]] ?? []).filter {
      guard let info = $0["Info"] as? [String: Any] else { return false }
      return info["DeviceClass"] as? String == profile.deviceClass
        && info["Variant"] as? String == variant
    }
    guard candidates.count == 1, let identity = candidates.first,
      try number(identity["ApChipID"]) == profile.chipID,
      try number(identity["ApBoardID"]) == profile.boardID,
      try number(identity["ApSecurityDomain"]) == profile.securityDomain
    else { throw MisoError.invalid("Missing, ambiguous or incompatible personalization identity") }
    return identity
  }

  static func request(_ kind: Kind, identity: [String: Any], ecid: UInt64, generator: UInt64) throws
    -> [String: Any]
  {
    guard ecid > 0, let build = identity["UniqueBuildID"] as? Data,
      let info = identity["Info"] as? [String: Any],
      let manifest = identity["Manifest"] as? [String: [String: Any]],
      let selected = components[kind]
    else { throw MisoError.invalid("Incomplete personalization identity") }
    let chip = try number(identity["ApChipID"])
    var request: [String: Any] = [
      "@HostPlatformInfo": "mac", "@VersionInfo": "libauthinstall-1049.100.21",
      "@UUID": UUID().uuidString,
      "@ApImg4Ticket": true, "ApECID": NSNumber(value: ecid), "ApChipID": NSNumber(value: chip),
      "ApBoardID": NSNumber(value: try number(identity["ApBoardID"])),
      "ApSecurityDomain": NSNumber(value: try number(identity["ApSecurityDomain"])),
      "ApProductionMode": true, "ApSecurityMode": true, "UniqueBuildID": build,
      "ApNonce": try nonce(generator),
    ]
    for (key, value) in identity where key.hasPrefix("Ap,") { request[key] = value }
    for key in info["RequestManifestProperties"] as? [String] ?? [] {
      guard let value = info[key] else {
        throw MisoError.invalid("Missing requested manifest property")
      }
      request[key] = value
    }
    if kind == .cryptex {
      let retained: Set<String> = [
        "@HostPlatformInfo", "@VersionInfo", "@UUID", "ApChipID", "ApBoardID", "ApSecurityDomain",
        "UniqueBuildID",
      ]
      request = request.filter { retained.contains($0.key) }
      request["@Cryptex1,Ticket"] = true
      for (key, value) in identity where key.hasPrefix("Cryptex1,") {
        request[key] =
          (value as? String)?.hasPrefix("0x") == true ? NSNumber(value: try number(value)) : value
      }
      request["Cryptex1,ProductionMode"] = true
      request["Cryptex1,UDID"] = udid(chip: chip, ecid: ecid)
      request["Cryptex1,Nonce"] = try nonce(generator)
      for name in selected {
        guard let digest = manifest[name]?["Digest"] as? Data else {
          throw MisoError.invalid("Missing cryptex digest")
        }
        request[name] = ["Digest": digest]
      }
      return request
    }
    if kind == .macos || kind == .sfr { request["SepNonce"] = Data(repeating: 0xAA, count: 20) }
    let conditions = [
      "ApRawProductionMode": true, "ApCurrentProductionMode": true, "ApRawSecurityMode": true,
      "ApRequiresImage4": true,
    ]
    for name in selected {
      guard let component = manifest[name], let info = component["Info"] as? [String: Any] else {
        throw MisoError.invalid("Missing personalization component")
      }
      var value = component.filter { $0.key != "Info" }
      for rule in info["RestoreRequestRules"] as? [[String: Any]] ?? [] {
        guard let expected = rule["Conditions"] as? [String: Any],
          let actions = rule["Actions"] as? [String: Any]
        else {
          throw MisoError.invalid("Invalid restore request rule")
        }
        if expected.allSatisfy({ condition in
          guard let actual = conditions[condition.key], let wanted = condition.value as? Bool else {
            return false
          }
          return actual == wanted
        }) {
          value.merge(actions) { _, new in new }
        }
      }
      request[name] = value
    }
    return request
  }

  static func udid(chip: UInt64, ecid: UInt64) -> Data {
    var chip = chip.bigEndian
    var ecid = ecid.bigEndian
    return withUnsafeBytes(of: &chip) { Data($0) } + withUnsafeBytes(of: &ecid) { Data($0) }
  }

  static func recovery(
    profile: RestoreProfile, ecid: UInt64, payload: Data, ticket: Data, nonces: Data, volume: UUID
  ) throws -> [String: Any] {
    guard nonces.count == 112, ecid > 0 else {
      throw MisoError.invalid("Invalid recovery policy identity")
    }
    var uuid = volume.uuid
    return [
      "@HostPlatformInfo": "mac", "@VersionInfo": "libauthinstall-1049.100.21",
      "@UUID": UUID().uuidString,
      "@ApImg4Ticket": true, "ApECID": NSNumber(value: ecid), "ApChipID": profile.chipID,
      "ApBoardID": profile.boardID, "ApSecurityDomain": profile.securityDomain,
      "ApProductionMode": true, "ApSecurityMode": true, "Ap,LocalBoot": true,
      "Ap,LocalPolicy": ["Digest": Data(SHA384.hash(data: payload)), "Trusted": true],
      "Ap,NextStageIM4MHash": Data(SHA384.hash(data: ticket)),
      "Ap,RecoveryOSPolicyNonceHash": Data(SHA384.hash(data: nonces[64..<80])),
      "Ap,VolumeUUID": withUnsafeBytes(of: &uuid) { Data($0) },
    ]
  }

  static func parse(_ data: Data, key: String) throws -> Data {
    guard data.count <= 8 << 20, let marker = data.range(of: Data("<?xml".utf8)),
      let prefix = String(data: data[..<marker.lowerBound], encoding: .ascii)
    else { throw MisoError.invalid("Missing or oversized ticket server response") }
    let status = URLComponents(string: "https://gs.apple.com/?" + prefix)?.queryItems ?? []
    guard status.filter({ $0.name == "STATUS" }).map(\.value) == ["0"],
      status.filter({ $0.name == "MESSAGE" }).map(\.value) == ["SUCCESS"]
    else { throw MisoError.invalid("Apple ticket server rejected personalization") }
    let body = try RestoreInspection.plist(Data(data[marker.lowerBound...]))
    guard let ticket = body[key] as? Data, ticket.count <= 1 << 20 else {
      throw MisoError.invalid("Missing or oversized personalization ticket")
    }
    _ = try Image4.manifestProperties(ticket)
    return ticket
  }

  @MainActor static func send(
    _ request: [String: Any], name: String, journal: ExecutionJournal, cryptex: Bool = false
  ) async throws -> Data {
    guard ["firmware", "macos", "cryptex", "sfr", "recovery-policy"].contains(name) else {
      throw MisoError.invalid("Invalid ticket request kind")
    }
    let directory = journal.output.appendingPathComponent("tss-" + name)
    try SafeFile.makeDirectory(directory)
    let body = try PropertyListSerialization.data(
      fromPropertyList: request, format: .xml, options: 0)
    try SafeFile.writeNew(body, to: directory.appendingPathComponent("request.plist"))
    let response = try await HTTPData.post(
      URL(string: "https://gs.apple.com/TSS/controller?action=2")!,
      body: body, maximumBytes: 8 << 20, cancellation: journal.cancellation)
    try SafeFile.writeNew(response, to: directory.appendingPathComponent("response.raw"))
    let ticket = try parse(response, key: cryptex ? "Cryptex1,Ticket" : "ApImg4Ticket")
    try SafeFile.writeNew(ticket, to: directory.appendingPathComponent("ticket.im4m"))
    return ticket
  }

  static func verify(
    _ ticket: Data, profile: RestoreProfile, ecid: UInt64, generator: UInt64? = nil,
    cryptex: Bool = false
  ) throws {
    guard let group = try Image4.manifestProperties(ticket)["MANP"] else {
      throw MisoError.invalid("Missing ticket environment")
    }
    let properties = try Image4.properties(group)
    var expected: [String: UInt64] = [
      "CHIP": UInt64(profile.chipID), "BORD": UInt64(profile.boardID),
      "SDOM": UInt64(profile.securityDomain), "CEPO": 1,
    ]
    if !cryptex { expected["ECID"] = ecid }
    for (key, value) in expected {
      guard properties[key] == DER.integer(value) else {
        throw MisoError.invalid("Ticket hardware mismatch: \(key)")
      }
    }
    for key in cryptex ? ["CPRO"] : ["CPRO", "CSEC"] {
      guard properties[key] == DER.encode(1, Data([0xFF])) else {
        throw MisoError.invalid("Ticket security state mismatch")
      }
    }
    if let generator {
      guard properties[cryptex ? "cnch" : "BNCH"] == (try DER.encode(4, nonce(generator))) else {
        throw MisoError.invalid("Ticket nonce mismatch")
      }
    }
    if cryptex, properties["UDID"] != DER.encode(4, udid(chip: UInt64(profile.chipID), ecid: ecid))
    {
      throw MisoError.invalid("Cryptex ticket identity mismatch")
    }
  }
}

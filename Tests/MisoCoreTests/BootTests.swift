import Compression
import CryptoKit
import Foundation
import Testing

@testable import MisoCore

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["MISO_TSS_PREPARED"] != nil
      && ProcessInfo.processInfo.environment["MISO_TSS_OUTPUT"] != nil))
@MainActor func liveRestoreTicketsAuthenticatePreparedComponents() async throws {
  let environment = ProcessInfo.processInfo.environment
  let directory = URL(fileURLWithPath: try #require(environment["MISO_TSS_PREPARED"]))
  let output = URL(fileURLWithPath: try #require(environment["MISO_TSS_OUTPUT"]))
  let inputs = try PreparedInputs(directory)
  let profile = inputs.receipt.profile
  let ecid = try #require(UInt64(inputs.receipt.ecid))
  let generator = try BootPersonalization.random(8).integer(at: 0, as: UInt64.self) | 1
  let journal = try ExecutionJournal(output: output, operation: "test-live-restore-tickets")
  do {
    let manifest = try RestoreInspection.plist(
      SafeFile.read(inputs.requireInput("BuildManifest.plist"), limit: 64 << 20))
    var tickets: [String: ImageBundle.FileRecord] = [:]
    for kind in RestoreTickets.Kind.allCases {
      let variant = kind == .firmware || kind == .sfr ? profile.restoreVariant : "macOS Customer"
      let identity = try RestoreTickets.identity(manifest, profile: profile, variant: variant)
      let request = try RestoreTickets.request(
        kind, identity: identity, ecid: ecid, generator: generator)
      let ticket = try await RestoreTickets.send(
        request, name: kind.rawValue, journal: journal, cryptex: kind == .cryptex)
      try RestoreTickets.verify(
        ticket, profile: profile, ecid: ecid, generator: generator, cryptex: kind == .cryptex)
      let name =
        kind == .firmware ? "LLB" : kind == .cryptex ? "Cryptex1,SystemVolume" : "KernelCache"
      let path = try BootPersonalization.componentPath(name, identity: identity, inputs: inputs)
      let payload = try SafeFile.read(path, limit: 128 << 20)
      let type = String(decoding: try Image4.payloadFields(payload)[1].content, as: UTF8.self)
      try Image4.verifyDigest(payload: payload, ticket: ticket, type: type)
      try Image4Trust.authenticate(
        Image4.stitch(payload: payload, ticket: ticket), type: type, decoder: .firmware)
      tickets[kind.rawValue] = try Artifacts.record(
        journal.output.appendingPathComponent("tss-" + kind.rawValue + "/ticket.im4m"),
        relativeTo: journal.output)
    }
    try journal.finish(tickets)
  } catch {
    try journal.fail(error)
    throw error
  }
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["MISO_POLICY_MATERIAL"] != nil
      && ProcessInfo.processInfo.environment["MISO_POLICY_PROPERTIES"] != nil))
func nativePolicyAuthenticatesPreparedMaterial() throws {
  let environment = ProcessInfo.processInfo.environment
  let directory = URL(fileURLWithPath: try #require(environment["MISO_POLICY_MATERIAL"]))
  let propertiesURL = URL(fileURLWithPath: try #require(environment["MISO_POLICY_PROPERTIES"]))
  let journal = try JSON.read(
    ExecutionJournal.Record.self, from: directory.appendingPathComponent("journal.json"))
  #expect(
    journal.operation == "prepare-policy-material" && journal.status == .complete
      && !journal.vmStarted)
  let receipt = try JSONDecoder().decode(
    KernelCollection.Receipt.self, from: JSON.encode(try #require(journal.result)))
  var material: [String: Data] = [:]
  for (name, record) in receipt.blobs {
    material[name] = try SafeFile.read(Artifacts.resolve(record, under: directory), limit: 1 << 20)
  }
  let chain = try #require(material["certificates"])
  let key = try LocalPolicy.key(#require(material["key"]), certificates: chain)
  let properties = try #require(
    RestoreInspection.plist(SafeFile.read(propertiesURL, limit: 1 << 20)) as? [String: Data])
  let signed = try LocalPolicy.sign(
    properties: properties, payload: #require(material["payload"]), key: key, chain: chain)
  #expect(signed.measurement.count == 48)
  #expect(try LocalPolicy.verify(signed.image, key: key.publicKey))
}

private func machoFixture() -> Data {
  var data = Data(count: 1024)
  for (offset, value) in [
    (0, 0xFEED_FACF), (4, 0x0100_000C), (12, 11), (16, 2), (20, 96),
    (32, 0x19), (36, 72), (104, 2), (108, 24), (112, 512), (116, 3), (120, 560), (124, 64),
  ] {
    data.put(UInt32(value), at: offset)
  }
  data.put(UInt64(0x1000), at: 56)
  data.put(UInt64(256), at: 72)
  data.put(UInt64(256), at: 80)
  data.replaceSubrange(256..<260, with: Data([1, 2, 3, 4]))
  let names = Data("\0value\0local\0".utf8)
  data.replaceSubrange(560..<560 + names.count, with: names)
  for (index, pair) in [(1, UInt64(0x1000)), (7, 0x1008), (7, 0x1010)].enumerated() {
    let offset = 512 + index * 16
    data.put(UInt32(pair.0), at: offset)
    data[offset + 4] = 0x0E
    data.put(pair.1, at: offset + 8)
  }
  return data
}

@Test func machoBoundsAndSymbolAmbiguityAreLocalToLookup() throws {
  let data = machoFixture()
  let image = try MachOImage(data)
  #expect(try image.bytes("value", count: 4) == Data([1, 2, 3, 4]))
  #expect(throws: (any Error).self) { try image.bytes("local", count: 1) }
  #expect(throws: (any Error).self) { try image.bytes("value", count: 257) }
  for offset in [36, 112, 116, 120, 124] {
    var corrupted = data
    corrupted.put(UInt32.max, at: offset)
    #expect(throws: (any Error).self) { try MachOImage(corrupted) }
  }
  #expect(throws: (any Error).self) { try MachOImage(Data(data.prefix(20))) }
  var collection = data
  collection.replaceSubrange(128..<256, with: data.prefix(128))
  collection.replaceSubrange(0..<128, with: Data(count: 128))
  for (offset, value) in [
    (0, 0xFEED_FACF), (4, 0x0100_000C), (12, 12), (16, 1), (20, 80), (32, 0x8000_0035), (36, 80),
    (56, 32),
  ] {
    collection.put(UInt32(value), at: offset)
  }
  collection.put(UInt64(128), at: 48)
  let name = Data("com.apple.fixture\0".utf8)
  collection.replaceSubrange(64..<64 + name.count, with: name)
  #expect(
    try MachOImage(collection).member("com.apple.fixture").bytes("value", count: 4)
      == Data([1, 2, 3, 4]))
}

@Test func nativeKernelDecompressionRejectsTruncationAndOversize() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let input = Data(repeating: 42, count: 64 << 10)
  var encoded = Data(count: input.count * 2)
  let count = encoded.withUnsafeMutableBytes { destination in
    input.withUnsafeBytes { source in
      compression_encode_buffer(
        destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
        source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
    }
  }
  #expect(count > 0)
  encoded = Data(encoded.prefix(count))
  let output = directory.url.appendingPathComponent("kernel")
  let cancellation = try CancellationToken()
  try KernelCollection.decompress(encoded, output: output, cancellation: cancellation)
  #expect(try SafeFile.read(output, limit: input.count) == input)
  #expect(throws: (any Error).self) {
    try KernelCollection.decompress(
      Data(encoded.dropLast()), output: directory.url.appendingPathComponent("truncated"),
      cancellation: cancellation)
  }
  #expect(throws: (any Error).self) {
    try KernelCollection.decompress(
      encoded, output: directory.url.appendingPathComponent("oversized"), maximumBytes: 32,
      cancellation: cancellation)
  }
}

@Test func ticketRequestsBindHardwareNonceAndCryptexIdentity() throws {
  let profile = RestoreProfile.supported[1]
  let names = Set(RestoreTickets.components.values.flatMap { $0 })
  let entries: [String: [String: Any]] = Dictionary(
    uniqueKeysWithValues: names.map {
      (
        $0,
        [
          "Digest": Data(repeating: 1, count: 48),
          "Info": [
            "RestoreRequestRules": [
              ["Conditions": ["ApRequiresImage4": true], "Actions": ["Trusted": true]]
            ]
          ],
        ]
      )
    })
  let identity: [String: Any] = [
    "ApChipID": "0xfe00", "ApBoardID": "0x20", "ApSecurityDomain": "0x1",
    "UniqueBuildID": Data([1, 2, 3]),
    "Info": ["DeviceClass": profile.deviceClass, "Variant": profile.restoreVariant],
    "Manifest": entries,
  ]
  _ = try RestoreTickets.identity(
    ["BuildIdentities": [identity]], profile: profile, variant: profile.restoreVariant)
  #expect(throws: (any Error).self) {
    try RestoreTickets.identity(
      ["BuildIdentities": [identity, identity]], profile: profile, variant: profile.restoreVariant)
  }
  let ecid = UInt64.max - 1
  let request = try RestoreTickets.request(.macos, identity: identity, ecid: ecid, generator: 123)
  #expect((request["ApECID"] as? NSNumber)?.uint64Value == ecid)
  #expect((request["KernelCache"] as? [String: Any])?["Trusted"] as? Bool == true)
  #expect(request["ApNonce"] as? Data == (try RestoreTickets.nonce(123)))
  var alternateIdentity = identity
  var alternateEntries = entries
  alternateEntries["LLB"] = [
    "Digest": Data(repeating: 1, count: 48),
    "Info": [
      "RestoreRequestRules": [
        ["Conditions": ["UnrecognizedRelease": "future"], "Actions": ["Trusted": false]],
        ["Conditions": ["ApRequiresImage4": true], "Actions": ["Trusted": true]],
      ]
    ],
  ]
  alternateIdentity["Manifest"] = alternateEntries
  let alternate = try RestoreTickets.request(
    .firmware, identity: alternateIdentity, ecid: ecid, generator: 123)
  #expect((alternate["LLB"] as? [String: Any])?["Trusted"] as? Bool == true)
  let cryptex = try RestoreTickets.request(.cryptex, identity: identity, ecid: ecid, generator: 123)
  #expect(cryptex["ApECID"] == nil && cryptex["@ApImg4Ticket"] == nil)
  #expect(cryptex["Cryptex1,UDID"] as? Data == RestoreTickets.udid(chip: 0xFE00, ecid: ecid))
  #expect(throws: (any Error).self) { try RestoreTickets.nonce(0) }
}

@Test func policyMeasurementExcludesNonceValuesButNotObjectIdentity() throws {
  let original = [
    "ECID": DER.integer(1), "CHIP": DER.integer(2),
    "lpnh": DER.encode(4, Data(repeating: 3, count: 48)),
  ]
  var changed = original
  changed["ECID"] = DER.integer(99)
  changed["lpnh"] = DER.encode(4, Data(repeating: 4, count: 48))
  #expect(try LocalPolicy.measurement(original) == LocalPolicy.measurement(changed))
  changed["CHIP"] = DER.integer(3)
  #expect(try LocalPolicy.measurement(original) != LocalPolicy.measurement(changed))
  let group = try #require(UUID(uuidString: "12345678-1234-5678-1234-567812345678"))
  #expect(BootTree.recoveryIdentifier(group).uuidString == "9C08A037-B4EB-5F54-960B-3610FE19769B")
}

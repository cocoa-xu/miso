import Compression
import Foundation
import Testing

@testable import MisoCore

private let fixtureIdentifiers = [
  "00112233-4455-6677-8899-aabbccddeeff", "11111111-2222-3333-4444-555555555555",
  "22222222-3333-4444-5555-666666666666", "33333333-4444-5555-6666-777777777777",
].map { UUID(uuidString: $0)! }

@Test func gptGoldenStructures() throws {
  let layout = try DiskLayout(
    diskBytes: 40 << 30, sourceBytes: 4096, identifiers: fixtureIdentifiers)
  let data = layout.structures()
  #expect(
    SafeFile.sha256(data.mbr + data.primary + data.entries + data.backup)
      == "f27a16fd1b24bf9249e98ab0a06c067a12a76550480f70006c0ca4ab0e201eac")
  #expect(layout.partitions[1].offset == 513 << 20)
  #expect(layout.partitions[2].size == 6 << 30)
  for header in [data.primary, data.backup] {
    let crc = try header.integer(at: 16, as: UInt32.self)
    var checked = Data(header.prefix(92))
    checked.put(UInt32(0), at: 16)
    #expect(checked.crc32 == crc)
  }
}

private let invalidGeometry: [(UInt64, UInt64)] = [
  (8 << 30, 4096), (40 << 30, 40 << 30), (40 << 30, 0), (.max, 4096), (40 << 30, 4095),
]

@Test(arguments: invalidGeometry)
func invalidDiskGeometry(_ sizes: (UInt64, UInt64)) {
  #expect(throws: (any Error).self) { try DiskLayout(diskBytes: sizes.0, sourceBytes: sizes.1) }
}

@Test func sparseSystemSeed() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  var system = Data(count: 4096)
  system.replaceSubrange(32..<36, with: "NXSB".utf8)
  system.put(UInt32(4096), at: 36)
  system.put(UInt64(1), at: 40)
  let source = directory.url.appendingPathComponent("source.apfs")
  let output = directory.url.appendingPathComponent("disk.img")
  try SafeFile.writeNew(system, to: source)
  let layout = try DiskLayout.create(
    source: source, output: output, diskBytes: 40 << 30, expectedSHA256: SafeFile.sha256(system))
  let handle = try SafeFile.openRegular(output)
  defer { try? handle.close() }
  #expect(try SafeFile.size(handle) == 40 << 30)
  #expect(try handle.readExactly(4096, at: layout.partitions[1].offset) == system)
  #expect(try handle.readExactly(8, at: layout.size - 512) == Data("EFI PART".utf8))
  #expect(throws: (any Error).self) {
    try DiskLayout.create(
      source: source, output: output, diskBytes: 40 << 30, expectedSHA256: SafeFile.sha256(system))
  }
}

private func pbzeHeader(_ numbers: [UInt64]) -> Data {
  var data = Data("pbze".utf8)
  for value in numbers {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
  }
  return data
}

@Test func pbzeStoredAndCompressed() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let payload = Data(repeating: 42, count: 8192)
  var compressed = Data(count: payload.count)
  let count = compressed.withUnsafeMutableBytes { destination in
    payload.withUnsafeBytes { source in
      compression_encode_buffer(
        destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
        source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
    }
  }
  #expect(count > 0 && count < payload.count)
  for (index, data) in [payload, Data(compressed.prefix(count))].enumerated() {
    let source = directory.url.appendingPathComponent("input-\(index)")
    let output = directory.url.appendingPathComponent("output-\(index)")
    try SafeFile.writeNew(pbzeHeader([8192, 8192, UInt64(data.count)]) + data, to: source)
    let receipt = try PBZE.decode(source: source, output: output)
    #expect(receipt.bytes == 8192 && receipt.sha256 == SafeFile.sha256(payload))
    #expect(try SafeFile.read(output, limit: 8192) == payload)
  }
}

@Test func pbzeRejectsInvalidBounds() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let cases = [
    pbzeHeader([0]), pbzeHeader([8192]), pbzeHeader([8192, 8193, 1]) + Data([0]),
    pbzeHeader([8192, 1, 2]) + Data([0, 0]),
  ]
  for (index, data) in cases.enumerated() {
    let input = directory.url.appendingPathComponent("in-\(index)")
    try SafeFile.writeNew(data, to: input)
    #expect(throws: (any Error).self) {
      try PBZE.decode(source: input, output: directory.url.appendingPathComponent("out-\(index)"))
    }
  }
}

@Test func nvramGoldenRoundTrip() throws {
  let variables = [("test", Data([0, 255, 1, 0, 0, 255])), ("long", Data(count: 260))]
  let bank = try NVRAM.encode(generation: 6, variables: variables)
  #expect(
    SafeFile.sha256(bank) == "942a058bd4a04ee2cebf0f23fdea80502878bb5ee2842abbfa4486a034656a50")
  let decoded = try NVRAM.decode(bank)
  #expect(
    decoded.generation == 6 && decoded.variables == Dictionary(uniqueKeysWithValues: variables))
  var corrupt = bank
  corrupt[42] ^= 1
  #expect(throws: (any Error).self) { try NVRAM.decode(corrupt) }
  #expect(throws: (any Error).self) {
    try NVRAM.encode(generation: 6, variables: [("bad=key", Data([1]))])
  }
  #expect(throws: (any Error).self) {
    try NVRAM.encode(generation: 6, variables: [("a", Data()), ("a", Data())])
  }
}

@Test func auxiliaryGoldenBytes() throws {
  let selection = AuxiliaryStorage.BootSelection(
    partitionType: DiskLayout.apfsType, partitionIdentifier: fixtureIdentifiers[2],
    systemIdentifier: fixtureIdentifiers[3])
  let data = try AuxiliaryStorage.assemble(
    empty: Data(count: AuxiliaryStorage.size), llb: Data("llb".utf8),
    appleLogo: Data("logo".utf8), nonces: Data(0..<112), generator: 0x1234_5678_9abc_def0,
    selection: selection, profile: RestoreProfile.supported[0])
  #expect(
    SafeFile.sha256(data) == "926fbd13500dc1896df9708600ff253ea286e55cdc12a0ab60ee38d6d448a230")
  try AuxiliaryStorage.verifyPanicLog(data)
  var corrupt = data
  corrupt[AuxiliaryStorage.panicLogOffset] = 255
  #expect(throws: (any Error).self) { try AuxiliaryStorage.verifyPanicLog(corrupt) }
}

@Test func accountPasswordGoldenBytes() throws {
  let entropy = try ImageConfiguration.derivePassword("admin", salt: Data(0..<32))
  #expect(
    SafeFile.hex(entropy)
      == "b5d4a4798f7c20a17dfaf6ba06283fe2f30951ad26c4737ddd7477bf14d480cd84b8b7e5c8627433ce9a97dec07cee6f479a0740e62a9ec64c624b956b3f6050b234719c8f03c877127267b81fde576e57ed505694747e20aadf3e0131b4f76914c21cfea6ed5a154f93e494c194ad5beda2fdc8bb23ae83f9acbffbc586cf43"
  )
  #expect(ImageConfiguration().fullName == "admin" && ImageConfiguration().timeZone == "GMT")
}

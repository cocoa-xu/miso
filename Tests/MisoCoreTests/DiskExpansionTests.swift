import Foundation
import Testing

@testable import MisoCore

private func expansionFixture(_ directory: URL) throws -> (FileHandle, Data) {
  let layout = try DiskLayout(diskBytes: 32 << 30, sourceBytes: 16 << 20)
  let structures = layout.structures()
  let size: UInt64 = 16 << 20
  var entries = structures.entries
  for (index, range) in [(2048, 4095), (4096, 16383), (16384, 28671)].enumerated() {
    entries.put(UInt64(range.0), at: index * 128 + 32)
    entries.put(UInt64(range.1), at: index * 128 + 40)
  }
  func checksum(_ data: inout Data) {
    data.put(UInt32(0), at: 16)
    data.put(data.prefix(92).crc32, at: 16)
  }
  var primary = structures.primary
  primary.put(size / 512 - 1, at: 32)
  primary.put(size / 512 - 34, at: 48)
  primary.put(entries.crc32, at: 88)
  checksum(&primary)
  var backup = primary
  backup.put(size / 512 - 1, at: 24)
  backup.put(UInt64(1), at: 32)
  backup.put(size / 512 - 33, at: 72)
  checksum(&backup)
  let file = try SafeFile.create(directory.appendingPathComponent("disk.img"))
  try file.truncate(atOffset: size)
  try file.seek(toOffset: 0)
  try file.write(contentsOf: structures.mbr + primary + entries)
  try file.seek(toOffset: size - 33 * 512)
  try file.write(contentsOf: entries + backup)
  try file.seek(toOffset: (2 << 20) + 97)
  try file.write(contentsOf: Data("main filesystem".utf8))
  let recovery =
    Data(repeating: 0x11, count: 2 << 20) + Data(repeating: 0, count: 2 << 20)
    + Data(repeating: 0x33, count: 2 << 20)
  try file.seek(toOffset: 8 << 20)
  try file.write(contentsOf: recovery)
  try file.synchronize()
  return (file, recovery)
}

@Test(arguments: [UInt64(18 << 20), UInt64(32 << 20)])
func diskExpansionPreservesIdentityAndMovesOverlappingRecovery(bytes: UInt64) throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let (file, recovery) = try expansionFixture(temporary.url)
  defer { try? file.close() }
  let original = try DiskExpansion.Table(file, bytes: 16 << 20)
  let result = try DiskExpansion.expand(file, to: bytes, cancellation: CancellationToken())
  let expanded = try DiskExpansion.Table(file, bytes: bytes)
  #expect(try file.readExactly(recovery.count, at: result.recoveryOffset) == recovery)
  #expect(try file.readExactly(15, at: (2 << 20) + 97) == Data("main filesystem".utf8))
  #expect(expanded.primary[56..<72] == original.primary[56..<72])
  for index in 0..<3 {
    let offset = index * 128
    #expect(expanded.entries[offset..<(offset + 32)] == original.entries[offset..<(offset + 32)])
    #expect(
      expanded.entries[(offset + 48)..<(offset + 128)]
        == original.entries[(offset + 48)..<(offset + 128)])
  }
  #expect(expanded.partitions[1].end == result.recoveryOffset)
  #expect(
    try file.readExactly(Int(result.recoveryOffset - (8 << 20)), at: 8 << 20).allSatisfy { $0 == 0 }
  )
  #expect(result.expandedBytes == bytes)
}

@Test func diskExpansionRejectsDamagedGPTAndShrinkingWithoutChangingPayload() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let (file, recovery) = try expansionFixture(temporary.url)
  defer { try? file.close() }
  #expect(throws: MisoError.self) {
    try DiskExpansion.expand(file, to: 8 << 20, cancellation: CancellationToken())
  }
  try file.seek(toOffset: 512 + 88)
  try file.write(contentsOf: Data([0, 0, 0, 0]))
  #expect(throws: MisoError.self) {
    try DiskExpansion.expand(file, to: 32 << 20, cancellation: CancellationToken())
  }
  #expect(try SafeFile.size(file) == 16 << 20)
  #expect(try file.readExactly(recovery.count, at: 8 << 20) == recovery)
}

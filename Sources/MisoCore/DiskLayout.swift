import CryptoKit
import Foundation

public struct DiskLayout: Encodable, Sendable {
  public static let sectorSize: UInt64 = 512
  public static let alignment: UInt64 = 1 << 20
  public static let iscType = UUID(uuidString: "69646961-6700-11AA-AA11-00306543ECAC")!
  public static let apfsType = UUID(uuidString: "7C3457EF-0000-11AA-AA11-00306543ECAC")!
  public static let recoveryType = UUID(uuidString: "52637672-7900-11AA-AA11-00306543ECAC")!

  public struct Partition: Encodable, Sendable {
    public let name: String
    public let type: UUID
    public let identifier: UUID
    public let offset: UInt64
    public let size: UInt64
    public var startLBA: UInt64 { offset / DiskLayout.sectorSize }
    public var endLBA: UInt64 { (offset + size) / DiskLayout.sectorSize - 1 }
  }

  public let identifier: UUID
  public let size: UInt64
  public let sourceSystemBytes: UInt64
  public let mainMaximumBytes: UInt64
  public let partitions: [Partition]

  public init(
    diskBytes: UInt64, sourceBytes: UInt64, identifiers: [UUID] = (0..<4).map { _ in UUID() }
  ) throws {
    let iscBytes: UInt64 = 512 << 20
    let recoveryBytes: UInt64 = 6 << 30
    let headroom: UInt64 = 8 << 30
    let mainStart = Self.alignment + iscBytes
    guard diskBytes <= Int64.max, diskBytes % Self.sectorSize == 0,
      sourceBytes > 0, sourceBytes % Self.sectorSize == 0,
      diskBytes > recoveryBytes + Self.alignment + mainStart + headroom,
      identifiers.count == 4, Set(identifiers).count == 4
    else { throw MisoError.invalid("Invalid disk geometry or partition identifiers") }
    let recoveryStart =
      (diskBytes - recoveryBytes - Self.alignment) / Self.alignment * Self.alignment
    guard sourceBytes <= recoveryStart - mainStart - headroom else {
      throw MisoError.invalid("Disk must hold System, reserved partitions and 8 GiB of headroom")
    }
    identifier = identifiers[0]
    size = diskBytes
    sourceSystemBytes = sourceBytes
    mainMaximumBytes = recoveryStart - mainStart
    partitions = [
      .init(
        name: "iSC", type: Self.iscType, identifier: identifiers[1], offset: Self.alignment,
        size: iscBytes),
      .init(
        name: "Macintosh HD", type: Self.apfsType, identifier: identifiers[2], offset: mainStart,
        size: sourceBytes),
      .init(
        name: "Recovery", type: Self.recoveryType, identifier: identifiers[3],
        offset: recoveryStart, size: recoveryBytes),
    ]
  }

  struct Structures {
    let mbr: Data
    let primary: Data
    let entries: Data
    let backup: Data
  }

  func structures() -> Structures {
    let sectors = size / Self.sectorSize
    var entries = Data(count: 128 * 128)
    for (index, partition) in partitions.enumerated() {
      let offset = index * 128
      entries.replaceSubrange(offset..<offset + 16, with: partition.type.gptBytes)
      entries.replaceSubrange(offset + 16..<offset + 32, with: partition.identifier.gptBytes)
      entries.put(partition.startLBA, at: offset + 32)
      entries.put(partition.endLBA, at: offset + 40)
      for (index, code) in partition.name.utf16.enumerated() {
        entries.put(code, at: offset + 56 + index * 2)
      }
    }
    func header(current: UInt64, backup: UInt64, entriesLBA: UInt64) -> Data {
      var data = Data(count: Int(Self.sectorSize))
      data.replaceSubrange(0..<8, with: "EFI PART".utf8)
      data.put(UInt32(0x10000), at: 8)
      data.put(UInt32(92), at: 12)
      data.put(current, at: 24)
      data.put(backup, at: 32)
      data.put(UInt64(34), at: 40)
      data.put(sectors - 34, at: 48)
      data.replaceSubrange(56..<72, with: identifier.gptBytes)
      data.put(entriesLBA, at: 72)
      data.put(UInt32(128), at: 80)
      data.put(UInt32(128), at: 84)
      data.put(entries.crc32, at: 88)
      data.put(data.prefix(92).crc32, at: 16)
      return data
    }
    var mbr = Data(count: Int(Self.sectorSize))
    mbr.replaceSubrange(446..<454, with: [0, 0, 2, 0, 0xee, 0xff, 0xff, 0xff])
    mbr.put(UInt32(1), at: 454)
    mbr.put(UInt32(min(sectors - 1, UInt64(UInt32.max))), at: 458)
    mbr.replaceSubrange(510..<512, with: [0x55, 0xaa])
    return Structures(
      mbr: mbr, primary: header(current: 1, backup: sectors - 1, entriesLBA: 2),
      entries: entries, backup: header(current: sectors - 1, backup: 1, entriesLBA: sectors - 33))
  }

  public static func create(source: URL, output: URL, diskBytes: UInt64, expectedSHA256: String)
    throws -> Self
  {
    try SafeFile.validateSHA256(expectedSHA256)
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let size = try SafeFile.size(input)
    let header = try input.readExactly(4096)
    let blockCount = try header.integer(at: 40, as: UInt64.self)
    guard header.subdata(in: 32..<36) == Data("NXSB".utf8),
      try header.integer(at: 36, as: UInt32.self) == 4096,
      blockCount <= UInt64.max / 4096, blockCount * 4096 == size
    else {
      throw MisoError.invalid("Source is not a complete raw APFS container")
    }
    let layout = try Self(diskBytes: diskBytes, sourceBytes: size)
    let structures = layout.structures()
    let destination = try SafeFile.create(output)
    defer { try? destination.close() }
    try destination.truncate(atOffset: diskBytes)
    try destination.seek(toOffset: 0)
    try destination.write(contentsOf: structures.mbr + structures.primary + structures.entries)
    try destination.seek(toOffset: diskBytes - 33 * sectorSize)
    try destination.write(contentsOf: structures.entries + structures.backup)
    try destination.seek(toOffset: layout.partitions[1].offset)
    try input.seek(toOffset: 0)
    var digest = SHA256()
    var copied: UInt64 = 0
    while copied < size {
      try autoreleasepool {
        let chunk = try input.readExactly(Int(min(8 << 20, size - copied)))
        try destination.write(contentsOf: chunk)
        digest.update(data: chunk)
        copied += UInt64(chunk.count)
      }
    }
    guard try SafeFile.size(input) == size, SafeFile.hex(digest.finalize()) == expectedSHA256 else {
      throw MisoError.invalid("System source digest mismatch; incomplete disk retained")
    }
    try destination.synchronize()
    return layout
  }
}

extension UUID {
  var bytes: Data {
    var value = uuid
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  var gptBytes: Data {
    let value = bytes
    return Data(value[0..<4].reversed()) + Data(value[4..<6].reversed())
      + Data(value[6..<8].reversed()) + value[8..<16]
  }
}

import Darwin
import Foundation

enum DiskExpansion {
  struct Receipt: Codable {
    let originalBytes: UInt64
    let expandedBytes: UInt64
    let recoveryBytes: UInt64
    let recoveryOffset: UInt64
    let vmStarted = false
  }

  static func run(image: URL, bytes: UInt64, journal: ExecutionJournal) throws -> Receipt {
    let disk = try DiskImageSession(image: image, readOnly: false, journal: journal)
    let receipt = try journal.measure(
      "expandGPTSeconds", progress: "Expand disk and relocate Recovery"
    ) {
      try disk.withDetachedFile { try expand($0, to: bytes, cancellation: journal.cancellation) }
    }
    try journal.measure("expandAPFSSeconds", progress: "Expand the APFS container") {
      try disk.withAttachment { session in
        let main = try BaseImageStage.mainContainer(session)
        try journal.run(
          "expand-apfs",
          NativeCommand(
            .disks,
            arguments: ["apfs", "resizeContainer", main.device, "0"], timeout: 900))
      }
    }
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    try audit.withAttachment { session in
      let containers = try session.containers()
      guard containers.count == 3 else {
        throw MisoError.invalid("Expected three expanded APFS containers")
      }
      for container in containers {
        let device = try APFSIdentity.rawVolume(container.stores[0].device)
        try journal.run(
          "verify-expanded-filesystem",
          NativeCommand("/sbin/fsck_apfs", arguments: ["-n", "-s", device], timeout: 900))
      }
    }
    return receipt
  }

  static func expand(_ file: FileHandle, to bytes: UInt64, cancellation: CancellationToken) throws
    -> Receipt
  {
    guard flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw MisoError.system("Lock disk for expansion", errno)
    }
    defer { _ = flock(file.fileDescriptor, LOCK_UN) }
    let size = try SafeFile.size(file)
    let table = try Table(file, bytes: size)
    guard bytes > size, bytes <= 2 << 40, bytes % 4096 == 0 else {
      throw MisoError.invalid(
        "Expansion requires a larger disk size aligned to 4096 bytes (up to 2 TiB)")
    }
    let recovery = table.partitions[2]
    let recoveryBytes = recovery.end - recovery.offset
    guard bytes > recoveryBytes + DiskLayout.alignment else {
      throw MisoError.invalid("Invalid expanded disk size")
    }
    let start =
      (bytes - recoveryBytes - DiskLayout.alignment) / DiskLayout.alignment * DiskLayout.alignment
    guard start > recovery.offset, start > table.partitions[1].end else {
      throw MisoError.invalid("Disk expansion leaves no additional APFS space")
    }
    try cancellation.check()
    try file.truncate(atOffset: bytes)
    var remaining = recoveryBytes
    let zeroes = Data(repeating: 0, count: 8 << 20)
    while remaining > 0 {
      try cancellation.check()
      let count = min(UInt64(zeroes.count), remaining)
      remaining -= count
      let data = try file.readExactly(Int(count), at: recovery.offset + remaining)
      if data == zeroes.prefix(Int(count)) {
        try punch(file, offset: start + remaining, bytes: count)
      } else {
        try file.seek(toOffset: start + remaining)
        try file.write(contentsOf: data)
      }
    }
    try punch(file, offset: table.partitions[1].end, bytes: start - table.partitions[1].end)
    var entries = table.entries
    entries.put(start / 512 - 1, at: 128 + 40)
    entries.put(start / 512, at: 256 + 32)
    entries.put((start + recoveryBytes) / 512 - 1, at: 256 + 40)
    let sectors = bytes / 512
    var primary = table.primary
    primary.put(sectors - 1, at: 32)
    primary.put(sectors - 34, at: 48)
    primary.put(entries.crc32, at: 88)
    checksum(&primary)
    var backup = primary
    backup.put(sectors - 1, at: 24)
    backup.put(UInt64(1), at: 32)
    backup.put(sectors - 33, at: 72)
    checksum(&backup)
    var mbr = table.mbr
    mbr.put(UInt32(min(sectors - 1, UInt64(UInt32.max))), at: 458)
    try file.seek(toOffset: bytes - 33 * 512)
    try file.write(contentsOf: entries + backup)
    try file.seek(toOffset: 0)
    try file.write(contentsOf: mbr + primary + entries)
    try file.synchronize()
    _ = try Table(file, bytes: bytes)
    return Receipt(
      originalBytes: size, expandedBytes: bytes, recoveryBytes: recoveryBytes, recoveryOffset: start
    )
  }

  private static func punch(_ file: FileHandle, offset: UInt64, bytes: UInt64) throws {
    var range = fpunchhole_t(
      fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(bytes))
    guard fcntl(file.fileDescriptor, F_PUNCHHOLE, &range) == 0 else {
      throw MisoError.system("Reclaim relocated disk blocks", errno)
    }
  }

  private static func checksum(_ header: inout Data) {
    header.put(UInt32(0), at: 16)
    header.put(header.prefix(92).crc32, at: 16)
  }

  struct Table {
    let mbr: Data
    let primary: Data
    let entries: Data
    let partitions: [APFSCompaction.Extent]

    init(_ file: FileHandle, bytes: UInt64) throws {
      guard bytes >= 4 << 20, bytes % 512 == 0 else {
        throw MisoError.invalid("Invalid GPT disk size")
      }
      mbr = try file.readExactly(512, at: 0)
      primary = try file.readExactly(512, at: 512)
      let sectors = bytes / 512
      let backup = try file.readExactly(512, at: bytes - 512)
      try Self.validate(primary, current: 1, backup: sectors - 1, table: 2, sectors: sectors)
      try Self.validate(
        backup, current: sectors - 1, backup: 1, table: sectors - 33, sectors: sectors)
      guard mbr[450] == 0xee, mbr[510] == 0x55, mbr[511] == 0xaa,
        primary[40..<72] == backup[40..<72], primary[80..<92] == backup[80..<92]
      else { throw MisoError.invalid("GPT headers disagree") }
      entries = try file.readExactly(128 * 128, at: 1024)
      guard try entries.crc32 == primary.integer(at: 88, as: UInt32.self),
        entries == (try file.readExactly(entries.count, at: bytes - 33 * 512)),
        entries.dropFirst(3 * 128).allSatisfy({ $0 == 0 })
      else { throw MisoError.invalid("Invalid three-partition GPT table") }
      let types = [DiskLayout.iscType, DiskLayout.apfsType, DiskLayout.recoveryType]
      var parsed: [APFSCompaction.Extent] = []
      var end: UInt64 = 34
      var identifiers = Set<Data>()
      for index in 0..<3 {
        let entry = entries.subdata(in: (index * 128)..<(index * 128 + 128))
        let first = try entry.integer(at: 32, as: UInt64.self)
        let last = try entry.integer(at: 40, as: UInt64.self)
        guard entry.prefix(16) == types[index].gptBytes, first >= end, first <= last,
          last <= sectors - 34, first % 8 == 0, (last + 1) % 8 == 0,
          identifiers.insert(entry.subdata(in: 16..<32)).inserted
        else { throw MisoError.invalid("Unsupported MISO partition layout") }
        parsed.append(.init(offset: first * 512, length: (last + 1 - first) * 512))
        end = last + 1
      }
      partitions = parsed
    }

    private static func validate(
      _ data: Data, current: UInt64, backup: UInt64, table: UInt64, sectors: UInt64
    ) throws {
      var header = data.prefix(92)
      header.put(UInt32(0), at: 16)
      guard data.prefix(8) == Data("EFI PART".utf8),
        try data.integer(at: 8, as: UInt32.self) == 0x10000,
        try data.integer(at: 12, as: UInt32.self) == 92,
        try data.integer(at: 16, as: UInt32.self) == header.crc32,
        try data.integer(at: 24, as: UInt64.self) == current,
        try data.integer(at: 32, as: UInt64.self) == backup,
        try data.integer(at: 40, as: UInt64.self) == 34,
        try data.integer(at: 48, as: UInt64.self) == sectors - 34,
        try data.integer(at: 72, as: UInt64.self) == table,
        try data.integer(at: 80, as: UInt32.self) == 128,
        try data.integer(at: 84, as: UInt32.self) == 128
      else { throw MisoError.invalid("Invalid MISO GPT header") }
    }
  }
}

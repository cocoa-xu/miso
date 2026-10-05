import Darwin
import Foundation

enum APFSCompaction {
  struct Extent: Equatable {
    var offset: UInt64
    var length: UInt64
    var end: UInt64 { offset + length }
  }

  struct Receipt: Codable {
    let containers: Int
    let ranges: Int
    let freeBytes: UInt64
    let allocatedBytesBefore: Int64
    let allocatedBytesAfter: Int64
  }

  static func run(_ session: DiskImageSession, cancellation: CancellationToken) throws -> Receipt {
    try session.withDetachedFile { try compact($0, cancellation: cancellation) }
  }

  static func compact(_ file: FileHandle, cancellation: CancellationToken) throws -> Receipt {
    let before = try metadata(file)
    guard before.st_nlink == 1, flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw MisoError.invalid("Compaction requires an exclusive image file")
    }
    defer { _ = flock(file.fileDescriptor, LOCK_UN) }
    let scanner = try Scanner(file, cancellation: cancellation)
    let plans = try scanner.scan()
    for extent in plans.joined() {
      try scanner.checkDeadline()
      var hole = fpunchhole_t(
        fp_flags: 0, reserved: 0, fp_offset: off_t(extent.offset),
        fp_length: off_t(extent.length))
      guard fcntl(file.fileDescriptor, F_PUNCHHOLE, &hole) == 0 else {
        throw MisoError.system("Punch APFS free blocks", errno)
      }
    }
    try file.synchronize()
    let after = try metadata(file)
    guard after.st_size == before.st_size else {
      throw MisoError.invalid("Compaction changed logical disk size")
    }
    return Receipt(
      containers: plans.count, ranges: plans.reduce(0) { $0 + $1.count },
      freeBytes: plans.joined().reduce(0) { $0 + $1.length },
      allocatedBytesBefore: before.st_blocks * 512, allocatedBytesAfter: after.st_blocks * 512)
  }

  private static func metadata(_ file: FileHandle) throws -> stat {
    var info = stat()
    guard fstat(file.fileDescriptor, &info) == 0 else {
      throw MisoError.system("Inspect compaction file", errno)
    }
    return info
  }

  final class Scanner {
    let file: FileHandle
    let size: UInt64
    let cancellation: CancellationToken?
    private let deadline = ProcessInfo.processInfo.systemUptime + 600

    init(_ file: FileHandle, cancellation: CancellationToken? = nil) throws {
      self.file = file
      size = try SafeFile.size(file)
      self.cancellation = cancellation
      try require(size >= 34 * 512 && size % 512 == 0, "Invalid raw disk size")
    }

    func checkDeadline() throws {
      try cancellation?.check()
      try require(ProcessInfo.processInfo.systemUptime < deadline, "APFS compaction timed out")
    }

    private func read(_ offset: UInt64, _ length: Int) throws -> Data {
      try checkDeadline()
      try require(offset <= size && UInt64(length) <= size - offset, "Metadata outside image")
      return try file.readExactly(length, at: offset)
    }

    func scan() throws -> [[Extent]] {
      let gpt = try read(512, 512)
      try validateHeader(gpt, current: 1, backup: size / 512 - 1)
      let backup = try read(size - 512, 512)
      try validateHeader(backup, current: size / 512 - 1, backup: 1)
      try require(
        gpt[40..<72] == backup[40..<72] && gpt[80..<92] == backup[80..<92],
        "GPT headers disagree")
      let count = Int(try field(gpt, 80, 4))
      let entrySize = try field(gpt, 84, 4)
      try require(count > 0 && count <= 1024 && entrySize == 128, "Unsupported GPT entries")
      let entriesLBA = try field(gpt, 72)
      let backupLBA = try field(backup, 72)
      let sectors = UInt64(count * 128 + 511) / 512
      let firstUsable = try field(gpt, 40)
      let lastUsable = try field(gpt, 48)
      try require(
        entriesLBA >= 2 && entriesLBA < firstUsable && sectors <= firstUsable - entriesLBA
          && firstUsable <= lastUsable && lastUsable < backupLBA
          && backupLBA < size / 512 - 1 && sectors <= size / 512 - 1 - backupLBA,
        "Invalid GPT table geometry")
      let entries = try read(entriesLBA * 512, count * 128)
      try require(UInt64(entries.crc32) == field(gpt, 88, 4), "GPT entries checksum mismatch")
      try require(entries == read(backupLBA * 512, count * 128), "GPT entry tables disagree")
      let types = [DiskLayout.iscType, DiskLayout.apfsType, DiskLayout.recoveryType].map(\.gptBytes)
      var end = firstUsable
      var plans = [[Extent]]()
      for index in 0..<count {
        let entry = Data(entries[(index * 128)..<(index * 128 + 128)])
        if entry.prefix(16).allSatisfy({ $0 == 0 }) { continue }
        let first = try field(entry, 32)
        let last = try field(entry, 40)
        try require(
          first >= end && last >= first && last <= lastUsable,
          "Invalid or overlapping GPT partition")
        end = last + 1
        guard types.contains(Data(entry.prefix(16))) else { continue }
        try require(first % 8 == 0 && (last + 1 - first) % 8 == 0, "Unaligned APFS partition")
        plans.append(try container(first * 512, (last + 1 - first) * 512))
      }
      try require(!plans.isEmpty, "No APFS containers found")
      return plans
    }

    private func validateHeader(_ data: Data, current: UInt64, backup: UInt64) throws {
      try require(data.prefix(8) == Data("EFI PART".utf8), "Expected GPT disk")
      let length = Int(try field(data, 12, 4))
      try require(length >= 92 && length <= 512, "Invalid GPT header size")
      var header = Data(data.prefix(length))
      header.put(UInt32(0), at: 16)
      try require(
        UInt64(header.crc32) == field(data, 16, 4)
          && field(data, 24) == current && field(data, 32) == backup,
        "GPT header checksum or location mismatch")
    }

    private func container(_ base: UInt64, _ bytes: UInt64) throws -> [Extent] {
      let prefix = try read(base, 4096)
      try require(
        field(prefix, 32, 4) == 0x4253_584e && field(prefix, 36, 4) == 4096
          && validObject(prefix), "Invalid APFS container superblock")
      let block: UInt64 = 4096
      let blocks = try field(prefix, 40)
      try require(blocks > 0 && blocks <= bytes / block, "Invalid APFS container size")
      var protected = [Extent(offset: 0, length: 1)]
      func protect(_ address: UInt64, _ length: UInt64) throws {
        try require(address <= blocks && length <= blocks - address, "Metadata outside container")
        if length > 0 { protected.append(Extent(offset: address, length: length)) }
      }
      func readBlock(_ address: UInt64) throws -> Data {
        try require(address < blocks, "Invalid APFS block address")
        return try read(base + address * block, 4096)
      }
      func object(_ address: UInt64, _ type: UInt64) throws -> Data {
        let data = try readBlock(address)
        try require(
          validObject(data) && field(data, 24, 4) & 0xffff == type,
          "Invalid APFS metadata object")
        try protect(address, 1)
        return data
      }
      let descriptorBase = try field(prefix, 112)
      let descriptorCount = try field(prefix, 104, 4)
      try require(descriptorCount > 0 && descriptorCount < 65536, "Unsupported checkpoint layout")
      try protect(descriptorBase, descriptorCount)
      var superblock = prefix
      var selectedAddress: UInt64 = 0
      for index in 0..<descriptorCount {
        let candidate = try readBlock(descriptorBase + index)
        if try field(candidate, 24, 4) & 0xffff == 1 && field(candidate, 32, 4) == 0x4253_584e
          && validObject(candidate) && field(candidate, 16) >= field(superblock, 16)
        {
          superblock = candidate
          selectedAddress = descriptorBase + index
        }
      }
      try require(
        superblock[72..<88] == prefix[72..<88] && field(superblock, 40) == blocks
          && field(superblock, 36, 4) == block && field(superblock, 112) == descriptorBase
          && field(superblock, 104, 4) == descriptorCount, "Checkpoint geometry changed")
      let transaction = try field(superblock, 16)
      let index = try field(superblock, 136, 4)
      let count = try field(superblock, 140, 4)
      try require(
        index < descriptorCount && count > 1 && count <= descriptorCount,
        "Invalid active checkpoint")
      try require(
        selectedAddress == descriptorBase + (index + count - 1) % descriptorCount,
        "Checkpoint does not end with selected superblock")
      try protect(field(superblock, 120), field(superblock, 108, 4))
      let spacemanID = try field(superblock, 152)
      var mappings = [UInt64]()
      for entry in 0..<(count - 1) {
        let data = try object(descriptorBase + (index + entry) % descriptorCount, 12)
        let mappingsCount = Int(try field(data, 36, 4))
        try require(
          field(data, 16) == transaction && mappingsCount <= (data.count - 40) / 40
            && field(data, 32, 4) == (entry == count - 2 ? 1 : 0),
          "Invalid active checkpoint mapping")
        for item in 0..<mappingsCount {
          let offset = 40 + item * 40
          if try field(data, offset + 24) == spacemanID {
            try require(
              field(data, offset, 4) & 0xffff == 5 && field(data, offset + 8, 4) == block,
              "Unsupported spaceman mapping")
            mappings.append(try field(data, offset + 32))
          }
        }
      }
      try require(mappings.count == 1, "Missing unique spaceman mapping")
      let sm = try object(mappings[0], 5)
      try require(
        field(sm, 8) == spacemanID && field(sm, 16) == transaction
          && field(sm, 32, 4) == block && field(sm, 48) == blocks && field(sm, 96) == 0
          && field(sm, 144, 4) <= 1, "Unsupported spaceman device or flags")
      let chunkBlocks = try field(sm, 36, 4)
      try require(chunkBlocks == block * 8, "Unsupported bitmap geometry")
      let poolCount = try field(sm, 152)
      let bitmapCount = try field(sm, 164, 4)
      try require(
        poolCount >> 63 == 0 && bitmapCount >> 31 == 0,
        "Fragmented internal pool is unsupported")
      try protect(field(sm, 176), poolCount)
      try protect(field(sm, 168), bitmapCount)
      let cibCount = Int(try field(sm, 64, 4))
      let addressOffset = Int(try field(sm, 80, 4))
      try require(
        cibCount > 0 && field(sm, 68, 4) == 0 && addressOffset >= 224
          && addressOffset <= sm.count && cibCount <= (sm.count - addressOffset) / 8,
        "Unsupported CIB indirection")
      var ranges = [Extent]()
      var covered: UInt64 = 0
      var free: UInt64 = 0
      var chunks: UInt64 = 0
      for cibIndex in 0..<cibCount {
        let cib = try object(field(sm, addressOffset + cibIndex * 8), 7)
        let entries = Int(try field(cib, 36, 4))
        try require(
          field(cib, 32, 4) == UInt64(cibIndex) && field(cib, 16) <= transaction
            && entries > 0 && entries <= (cib.count - 40) / 32, "Invalid CIB index/count")
        for entry in 0..<entries {
          try checkDeadline()
          let start = 40 + entry * 32
          let first = try field(cib, start + 8)
          let length = try field(cib, start + 16, 4)
          let expectedFree = try field(cib, start + 20, 4)
          let bitmapAddress = try field(cib, start + 24)
          try require(
            first == covered && length > 0 && length <= chunkBlocks
              && first <= blocks && length <= blocks - first
              && field(cib, start) <= transaction && expectedFree <= length,
            "Invalid chunk coverage or state")
          let bitmap: Data
          if bitmapAddress != 0 {
            bitmap = try readBlock(bitmapAddress)
            try protect(bitmapAddress, 1)
          } else {
            try require(expectedFree == length, "Missing nonempty allocation bitmap")
            bitmap = Data()
          }
          var chunkFree: UInt64 = 0
          for bit in 0..<length {
            if bitmapAddress == 0 || bitmap[Int(bit / 8)] & (1 << Int(bit % 8)) == 0 {
              if ranges.last?.end == first + bit {
                ranges[ranges.count - 1].length += 1
              } else {
                ranges.append(Extent(offset: first + bit, length: 1))
              }
              chunkFree += 1
            }
          }
          try require(
            chunkFree == expectedFree && ranges.count <= 4_000_000,
            "Invalid free-block count or excessive fragmentation")
          free += chunkFree
          covered += length
          chunks += 1
        }
      }
      try require(
        covered == blocks && free == field(sm, 72) && chunks == field(sm, 56),
        "Spaceman totals differ")
      for extent in protected {
        try checkDeadline()
        try require(
          !ranges.contains { $0.offset < extent.end && extent.offset < $0.end },
          "Allocation bitmap frees protected metadata")
      }
      return ranges.map { Extent(offset: base + $0.offset * block, length: $0.length * block) }
    }
  }

  static func field(_ data: Data, _ offset: Int, _ length: Int = 8) throws -> UInt64 {
    if length == 4 { return UInt64(try data.integer(at: offset, as: UInt32.self)) }
    return try data.integer(at: offset, as: UInt64.self)
  }

  static func validObject(_ data: Data) throws -> Bool {
    try require(data.count >= 32 && data.count % 4 == 0, "Invalid APFS object size")
    let modulus: UInt64 = 0xffff_ffff
    var a: UInt64 = 0
    var b: UInt64 = 0
    for offset in stride(from: 8, to: data.count, by: 4) {
      a = (a + (try field(data, offset, 4))) % modulus
      b = (b + a) % modulus
    }
    let lower = modulus - (a + b) % modulus
    let upper = modulus - (a + lower) % modulus
    return try field(data, 0) == lower | (upper << 32)
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw MisoError.invalid(message) }
  }
}

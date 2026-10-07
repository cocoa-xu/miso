import Darwin
import Foundation

enum IntelTrimming {
  struct Slice: Equatable {
    let cpu: UInt32
    let subtype: UInt32
    let offset: UInt64
    let size: UInt64
    let alignment: UInt32

    var intel: Bool { cpu == 7 || cpu == 0x0100_0007 }
    var arm64: Bool { cpu == 0x0100_000C }
  }

  struct Receipt: Codable {
    var filesTrimmed = 0
    var filesRemoved = 0
    var incompleteHardlinks = 0
    var unsupportedArchitectures = 0
    var logicalBytesRemoved: UInt64 = 0
    let retainedSlicesByteIdentical = true
    let signaturesReplaced = false
  }

  private struct Group {
    let original: stat
    let slices: [Slice]
    var paths: [URL]
  }

  static func slices(_ header: Data, size: UInt64) throws -> [Slice] {
    guard header.count >= 8 else { return [] }
    let magic = try header.integer(at: 0, as: UInt32.self)
    let wide: Bool
    let swap: Bool
    switch magic {
    case 0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE:
      guard header.count >= 12, size >= 28 else {
        throw MisoError.invalid("Truncated Mach-O header")
      }
      let swap = magic == 0xCEFA_EDFE || magic == 0xCFFA_EDFE
      let cpu = try header.integer(at: 4, as: UInt32.self)
      let subtype = try header.integer(at: 8, as: UInt32.self)
      return [
        Slice(
          cpu: swap ? cpu.byteSwapped : cpu,
          subtype: swap ? subtype.byteSwapped : subtype, offset: 0, size: size, alignment: 0)
      ]
    case 0xBEBA_FECA:
      wide = false
      swap = true
    case 0xCAFE_BABE:
      wide = false
      swap = false
    case 0xBFBA_FECA:
      wide = true
      swap = true
    case 0xCAFE_BABF:
      wide = true
      swap = false
    default: return []
    }
    func u32(_ offset: Int) throws -> UInt32 {
      let value = try header.integer(at: offset, as: UInt32.self)
      return swap ? value.byteSwapped : value
    }
    func u64(_ offset: Int) throws -> UInt64 {
      let value = try header.integer(at: offset, as: UInt64.self)
      return swap ? value.byteSwapped : value
    }
    let count = Int(try u32(4))
    let stride = wide ? 32 : 20
    let tableEnd = 8 + count * stride
    guard (1...128).contains(count), tableEnd <= header.count else {
      throw MisoError.invalid("Invalid universal architecture table")
    }
    var result: [Slice] = []
    for index in 0..<count {
      let cursor = 8 + index * stride
      let offset = try wide ? u64(cursor + 8) : UInt64(u32(cursor + 8))
      let length = try wide ? u64(cursor + 16) : UInt64(u32(cursor + 12))
      let alignment = try u32(cursor + (wide ? 24 : 16))
      guard offset >= UInt64(tableEnd), offset <= size, length > 0, length <= size - offset,
        alignment <= 30, offset % (1 << alignment) == 0
      else { throw MisoError.invalid("Invalid universal architecture bounds") }
      result.append(
        Slice(
          cpu: try u32(cursor), subtype: try u32(cursor + 4),
          offset: offset, size: length, alignment: alignment))
    }
    var end = UInt64(tableEnd)
    for slice in result.sorted(by: { $0.offset < $1.offset }) {
      guard slice.offset >= end else { throw MisoError.invalid("Overlapping architecture slices") }
      end = slice.offset + slice.size
    }
    return result
  }

  static func run(data: GuestVolume, roots: [String], cancellation: CancellationToken) throws
    -> Receipt
  {
    var groups: [ino_t: Group] = [:]
    var seen = Set<ino_t>()
    let deadline = ProcessInfo.processInfo.systemUptime + 5400
    func check() throws {
      try cancellation.check()
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw MisoError.invalid("Intel trimming timed out")
      }
    }
    for relative in roots {
      let root = try data.directory(relative).url
      try FileMetadata.walk(root) { path, info in
        try check()
        guard info.st_mode & S_IFMT == S_IFREG else { return }
        let url = root.appendingPathComponent(path)
        if groups[info.st_ino] != nil {
          groups[info.st_ino]!.paths.append(url)
          return
        }
        guard seen.insert(info.st_ino).inserted, info.st_size >= 8 else { return }
        let file = try SafeFile.openRegular(url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 8 + 128 * 32) ?? Data()
        guard let slices = try? slices(header, size: UInt64(info.st_size)),
          slices.contains(where: \.intel)
        else { return }
        groups[info.st_ino] = Group(original: info, slices: slices, paths: [url])
      }
    }
    var receipt = Receipt()
    for group in groups.values.sorted(by: { $0.paths[0].path < $1.paths[0].path }) {
      try check()
      guard Int(group.original.st_nlink) == group.paths.count else {
        receipt.incompleteHardlinks += 1
        continue
      }
      guard group.slices.allSatisfy({ $0.intel || $0.arm64 }),
        group.original.st_flags & ~UInt32(UF_COMPRESSED) == 0
      else {
        receipt.unsupportedArchitectures += 1
        continue
      }
      for path in group.paths {
        let info = try FileMetadata.inspect(path)
        guard info.st_ino == group.original.st_ino, info.st_size == group.original.st_size,
          info.st_dev == group.original.st_dev
        else { throw MisoError.invalid("Intel trimming input changed") }
      }
      let retained = group.slices.filter(\.arm64)
      if retained.isEmpty {
        for path in group.paths {
          guard unlink(path.path) == 0 else {
            throw MisoError.system("Remove Intel-only file", errno)
          }
        }
        receipt.filesRemoved += 1
        receipt.logicalBytesRemoved += UInt64(group.original.st_size)
      } else {
        let size = try trim(group, retained: retained, cancellation: cancellation)
        receipt.filesTrimmed += 1
        receipt.logicalBytesRemoved += UInt64(group.original.st_size) - size
      }
    }
    return receipt
  }

  private static func trim(_ group: Group, retained: [Slice], cancellation: CancellationToken)
    throws -> UInt64
  {
    let source = group.paths[0]
    let temporary = source.deletingLastPathComponent().appendingPathComponent(
      ".miso-thin-" + UUID().uuidString)
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    let output = try SafeFile.create(temporary)
    defer {
      try? output.close()
      _ = unlink(temporary.path)
    }
    var offsets: [UInt64] = []
    if retained.count == 1 {
      offsets = [0]
    } else {
      var header = Data(count: 8 + retained.count * 20)
      header.put(UInt32(0xCAFE_BABE).bigEndian, at: 0)
      header.put(UInt32(retained.count).bigEndian, at: 4)
      var position = UInt64(header.count)
      for (index, slice) in retained.enumerated() {
        let alignment = UInt64(1) << slice.alignment
        position = (position + alignment - 1) / alignment * alignment
        offsets.append(position)
        guard position <= UInt32.max, slice.size <= UInt32.max else {
          throw MisoError.unsupported("Trimmed universal file exceeds 32-bit archive bounds")
        }
        let cursor = 8 + index * 20
        header.put(slice.cpu.bigEndian, at: cursor)
        header.put(slice.subtype.bigEndian, at: cursor + 4)
        header.put(UInt32(position).bigEndian, at: cursor + 8)
        header.put(UInt32(slice.size).bigEndian, at: cursor + 12)
        header.put(slice.alignment.bigEndian, at: cursor + 16)
        position += slice.size
      }
      try output.write(contentsOf: header)
    }
    for (slice, offset) in zip(retained, offsets) {
      try input.seek(toOffset: slice.offset)
      try output.seek(toOffset: offset)
      var remaining = slice.size
      while remaining > 0 {
        try cancellation.check()
        let count = Int(min(remaining, 1 << 20))
        try output.write(contentsOf: input.readExactly(count))
        remaining -= UInt64(count)
      }
      try input.seek(toOffset: slice.offset)
      try output.seek(toOffset: offset)
      remaining = slice.size
      while remaining > 0 {
        try cancellation.check()
        let count = Int(min(remaining, 1 << 20))
        guard try input.readExactly(count) == output.readExactly(count) else {
          throw MisoError.invalid("Retained architecture bytes changed")
        }
        remaining -= UInt64(count)
      }
    }
    let size = try SafeFile.size(output)
    guard size < UInt64(group.original.st_size) else {
      throw MisoError.invalid("Intel trimming did not reduce logical size")
    }
    _ = try FileMetadata.restoreAttributes(
      source, to: temporary,
      ignoringCompression: group.original.st_flags & UInt32(UF_COMPRESSED) != 0)
    try FileMetadata.repair(temporary, expected: group.original)
    guard copyfile(source.path, temporary.path, nil, UInt32(COPYFILE_ACL | COPYFILE_NOFOLLOW)) == 0
    else {
      throw MisoError.system("Preserve trimmed file ACL", errno)
    }
    try TransparentCompression.restoreTimes(temporary, group.original)
    for (index, path) in group.paths.enumerated() {
      if index > 0, link(source.path, temporary.path) != 0 {
        throw MisoError.system("Preserve trimmed hardlink", errno)
      }
      guard rename(temporary.path, path.path) == 0 else {
        throw MisoError.system("Publish trimmed file", errno)
      }
    }
    guard try FileMetadata.inspect(source).st_nlink == group.original.st_nlink else {
      throw MisoError.invalid("Trimmed hardlink count changed")
    }
    return size
  }
}

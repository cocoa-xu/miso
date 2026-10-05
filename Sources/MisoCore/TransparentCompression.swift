import Compression
import Darwin
import Foundation

enum TransparentCompression {
  struct Receipt: Codable {
    var filesExamined = 0
    var filesCompressed = 0
    var pathsCompressed = 0
    var bytesSaved: Int64 = 0
  }

  private struct Group {
    let original: stat
    var paths: [URL]
  }

  static func run(
    data: GuestVolume, roots: [String], workspace: URL, cancellation: CancellationToken
  ) throws -> Receipt {
    let deadline = ProcessInfo.processInfo.systemUptime + 7200
    func check() throws {
      try cancellation.check()
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw MisoError.invalid("Payload compression timed out")
      }
    }
    var filesystem = statfs()
    guard statfs(data.root.path, &filesystem) == 0 else {
      throw MisoError.system("Inspect compression filesystem", errno)
    }
    let block = Int64(filesystem.f_bsize)
    var groups: [ino_t: Group] = [:]
    var directories: [(URL, stat)] = []
    var seen = Set<ino_t>()
    var receipt = Receipt()
    for relative in roots {
      try check()
      guard try data.contains(relative) else { continue }
      let root = try data.directory(relative).url
      directories.append((root, try FileMetadata.inspect(root)))
      try FileMetadata.walk(root) { path, info in
        try check()
        let url = root.appendingPathComponent(path)
        if info.st_mode & S_IFMT == S_IFDIR { directories.append((url, info)) }
        guard info.st_mode & S_IFMT == S_IFREG else { return }
        if seen.insert(info.st_ino).inserted { receipt.filesExamined += 1 }
        guard info.st_size > block && info.st_size <= 512 << 20 else { return }
        if groups[info.st_ino] == nil { groups[info.st_ino] = Group(original: info, paths: []) }
        groups[info.st_ino]!.paths.append(url)
      }
    }
    for group in groups.values.sorted(by: { $0.paths[0].path < $1.paths[0].path }) {
      try check()
      let saved = try autoreleasepool {
        try compress(group, workspace: workspace, volume: data.root, cancellation: cancellation)
      }
      if saved > 0 {
        receipt.filesCompressed += 1
        receipt.pathsCompressed += group.paths.count
        receipt.bytesSaved += saved
      }
    }
    for (path, info) in directories.reversed() { try restoreTimes(path, info) }
    return receipt
  }

  private static func compress(
    _ group: Group, workspace: URL, volume: URL, cancellation: CancellationToken
  ) throws -> Int64 {
    let original = group.original
    let paths = group.paths
    let path = paths[0]
    let excluded: Set<String> = [
      "dmg", "img", "ipsw", "xip", "pkg", "zip", "gz", "bz2", "xz", "zst", "aar", "jar",
      "sqlite", "sqlite3", "db",
    ]
    guard original.st_flags & ~UInt32(UF_COMPRESSED) == 0,
      Int(original.st_nlink) == paths.count,
      !paths.contains(where: { excluded.contains($0.pathExtension.lowercased()) })
    else { return 0 }
    if original.st_flags & UInt32(UF_COMPRESSED) == 0 {
      let forkSize = getxattr(
        path.path, "com.apple.ResourceFork", nil, 0, 0, FileMetadata.xattrOptions)
      guard forkSize >= 0 || errno == ENOATTR else {
        throw MisoError.system("Inspect existing resource fork", errno)
      }
      if forkSize > 0 || original.st_blocks * 512 < original.st_size { return 0 }
    } else {
      var header = Data(count: 16)
      let count = header.withUnsafeMutableBytes {
        getxattr(path.path, "com.apple.decmpfs", $0.baseAddress, 16, 0, FileMetadata.xattrOptions)
      }
      if count == 16, try header.integer(at: 4, as: UInt32.self) == 12 { return 0 }
    }
    guard unchanged(try FileMetadata.inspect(path), original) else {
      throw MisoError.invalid("Compression input changed")
    }
    try Artifacts.requireSpace(UInt64(max(1 << 30, original.st_size * 2)), at: workspace)
    try Artifacts.requireSpace(UInt64(max(512 << 20, original.st_size * 2)), at: volume)
    let bytes = try SafeFile.read(path, limit: 512 << 20)
    guard let fork = try encode(bytes, cancellation: cancellation) else { return 0 }
    let parent = path.deletingLastPathComponent()
    let temporary = parent.appendingPathComponent(".miso-compress-" + UUID().uuidString)
    let candidate = try SafeFile.create(temporary)
    defer {
      try? candidate.close()
      _ = unlink(temporary.path)
    }
    var header = Data(count: 16)
    header.put(UInt32(0x636d_7066), at: 0)
    header.put(UInt32(12), at: 4)
    header.put(UInt64(bytes.count), at: 8)
    let status = header.withUnsafeBytes {
      fsetxattr(
        candidate.fileDescriptor, "com.apple.decmpfs", $0.baseAddress, $0.count, 0,
        XATTR_SHOWCOMPRESSION)
    }
    guard status == 0 else { throw MisoError.system("Write compression header", errno) }
    let descriptor = open(
      temporary.path + "/..namedfork/rsrc", O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw MisoError.system("Open compression resource fork", errno) }
    let resource = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try resource.write(contentsOf: fork)
    try resource.close()
    guard fchflags(candidate.fileDescriptor, UInt32(UF_COMPRESSED)) == 0 else {
      throw MisoError.system("Enable transparent compression", errno)
    }
    var offset = 0
    while offset < bytes.count {
      try cancellation.check()
      let count = min(1 << 20, bytes.count - offset)
      guard try candidate.readExactly(count) == bytes[offset..<(offset + count)] else {
        throw MisoError.invalid("Transparent compression changed file contents")
      }
      offset += count
    }
    guard try SafeFile.size(candidate) == UInt64(bytes.count) else {
      throw MisoError.invalid("Transparent compression changed file size")
    }
    _ = try FileMetadata.restoreAttributes(path, to: temporary, ignoringCompression: true)
    try FileMetadata.repair(temporary, expected: original)
    guard copyfile(path.path, temporary.path, nil, UInt32(COPYFILE_ACL | COPYFILE_NOFOLLOW)) == 0
    else { throw MisoError.system("Preserve compressed file ACL", errno) }
    try restoreTimes(temporary, original)
    let restored = try FileMetadata.inspect(temporary)
    guard FileMetadata.equivalent(restored, original),
      try FileMetadata.acl(path) == FileMetadata.acl(temporary),
      restored.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
      restored.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
      restored.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec,
      restored.st_birthtimespec.tv_nsec == original.st_birthtimespec.tv_nsec
    else { throw MisoError.invalid("Compressed file metadata differs") }
    guard restored.st_blocks < original.st_blocks else { return 0 }
    for target in paths {
      guard unchanged(try FileMetadata.inspect(target), original) else {
        throw MisoError.invalid("Compression input identity changed")
      }
    }
    for (index, target) in paths.enumerated() {
      if index > 0, link(path.path, temporary.path) != 0 {
        throw MisoError.system("Preserve compressed hardlink", errno)
      }
      guard rename(temporary.path, target.path) == 0 else {
        throw MisoError.system("Publish compressed file", errno)
      }
    }
    guard try FileMetadata.inspect(path).st_nlink == original.st_nlink else {
      throw MisoError.invalid("Compressed hardlink count differs")
    }
    return (original.st_blocks - restored.st_blocks) * 512
  }

  static func encode(_ bytes: Data, cancellation: CancellationToken?) throws -> Data? {
    guard !bytes.isEmpty && bytes.count <= 512 << 20 else {
      throw MisoError.invalid("Invalid transparent compression size")
    }
    let chunkSize = 64 << 10
    let count = (bytes.count + chunkSize - 1) / chunkSize
    var fork = Data(count: (count + 1) * 4)
    var buffer = [UInt8](repeating: 0, count: chunkSize + 4096)
    try bytes.withUnsafeBytes { source in
      for index in 0..<count {
        try cancellation?.check()
        fork.put(UInt32(fork.count), at: index * 4)
        let start = index * chunkSize
        let written = compression_encode_buffer(
          &buffer, buffer.count,
          source.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self),
          min(chunkSize, bytes.count - start), nil, COMPRESSION_LZFSE)
        guard written > 0 else { throw MisoError.invalid("LZFSE encoding failed") }
        fork.append(contentsOf: buffer.prefix(written))
      }
    }
    fork.put(UInt32(fork.count), at: count * 4)
    return fork.count < bytes.count ? fork : nil
  }

  private static func unchanged(_ actual: stat, _ expected: stat) -> Bool {
    actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
      && actual.st_size == expected.st_size && actual.st_nlink == expected.st_nlink
      && actual.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec
      && actual.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
      && actual.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec
      && actual.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
  }

  private static func restoreTimes(_ path: URL, _ info: stat) throws {
    var fields = attrlist()
    fields.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    fields.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME)
    var times = [info.st_birthtimespec, info.st_mtimespec, info.st_atimespec]
    guard
      setattrlist(
        path.path, &fields, &times, MemoryLayout<timespec>.stride * times.count,
        UInt32(FSOPT_NOFOLLOW)) == 0
    else {
      throw MisoError.system("Preserve compression timestamps", errno)
    }
  }
}

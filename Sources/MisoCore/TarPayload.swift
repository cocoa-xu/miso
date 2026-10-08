import CMiso
import Darwin
import Foundation

enum TarPayload {
  struct Entry: Codable, Equatable {
    let path: String
    let kind: UInt16
    let mode: UInt16
    let bytes: Int64
    let link: String?
    let hardlink: String?

    init(
      path: String, kind: UInt16, mode: UInt16, bytes: Int64, link: String?, hardlink: String? = nil
    ) {
      self.path = path
      self.kind = kind
      self.mode = mode
      self.bytes = bytes
      self.link = link
      self.hardlink = hardlink
    }
  }

  static func inspect(
    _ source: URL, pathPrefix: String? = nil, cancellation: CancellationToken? = nil
  ) throws -> [Entry] {
    var entries: [Entry] = []
    try read(source, cancellation: cancellation) { entry, _ in entries.append(entry) }
    try validate(entries, pathPrefix: pathPrefix)
    return entries
  }

  static func validate(_ entries: [Entry], pathPrefix: String? = nil) throws {
    if let pathPrefix {
      _ = try SafeFile.relativePath(pathPrefix)
      return try validate(
        entries.map {
          Entry(
            path: pathPrefix + "/" + $0.path, kind: $0.kind, mode: $0.mode,
            bytes: $0.bytes, link: $0.link, hardlink: $0.hardlink.map { pathPrefix + "/" + $0 })
        })
    }
    guard !entries.isEmpty, entries.count <= 100_000,
      Set(entries.map(\.path)).count == entries.count
    else { throw MisoError.invalid("Empty, duplicate or excessive tar entries") }
    let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    for entry in entries {
      _ = try SafeFile.relativePath(entry.path)
      if let hardlink = entry.hardlink {
        _ = try SafeFile.relativePath(hardlink)
        guard entry.kind == S_IFREG, entry.bytes == 0, entry.link == nil,
          let target = byPath[hardlink], target.kind == S_IFREG, target.link == nil,
          target.hardlink == nil, target.mode == entry.mode
        else {
          throw MisoError.invalid("Invalid tar hardlink: \(entry.path)")
        }
      }
      var parents = entry.path.split(separator: "/").dropLast()
      while !parents.isEmpty {
        if let parent = byPath[parents.joined(separator: "/")], parent.kind != S_IFDIR {
          throw MisoError.invalid("Tar entry has a non-directory ancestor")
        }
        parents = parents.dropLast()
      }
      if let link = entry.link {
        _ = try SafeFile.relativeLink(link, at: entry.path)
        var pending = Array(entry.path.split(separator: "/").map(String.init).reversed())
        var resolved: [String] = []
        var links = 0
        while let part = pending.popLast() {
          if part == "." { continue }
          if part == ".." {
            guard !resolved.isEmpty else {
              throw MisoError.invalid(
                "Tar symlink chain escapes its root: \(entry.path) -> \(link)")
            }
            resolved.removeLast()
          } else if let target = byPath[(resolved + [part]).joined(separator: "/")]?.link {
            links += 1
            guard links <= 40 else { throw MisoError.invalid("Cyclic tar symlink chain") }
            pending += target.split(separator: "/").map(String.init).reversed()
          } else {
            resolved.append(part)
          }
        }
      }
    }
  }

  static func file(
    _ source: URL, path: String, maximumBytes: Int, cancellation: CancellationToken? = nil
  ) throws -> Data {
    _ = try SafeFile.relativePath(path)
    guard (1...(256 << 20)).contains(maximumBytes) else {
      throw MisoError.invalid("Invalid tar member limit")
    }
    var entries: [Entry] = []
    var result: Data?
    try read(source, cancellation: cancellation) { entry, reader in
      entries.append(entry)
      guard entry.path == path else { return }
      guard result == nil, entry.kind == S_IFREG, entry.link == nil, entry.hardlink == nil,
        entry.bytes <= maximumBytes
      else { throw MisoError.invalid("Invalid tar member") }
      var data = Data(count: Int(entry.bytes))
      var consumed = 0
      while consumed < data.count {
        try cancellation?.check()
        let count = min(1 << 20, data.count - consumed)
        let read = data.withUnsafeMutableBytes {
          archive_read_data(reader, $0.baseAddress!.advanced(by: consumed), count)
        }
        guard read > 0, read <= count else { throw MisoError.invalid("Truncated tar member") }
        consumed += read
      }
      result = data
    }
    try validate(entries)
    guard let result else { throw MisoError.invalid("Missing tar member: \(path)") }
    return result
  }

  static func extract(
    _ source: URL, into destination: URL, entries: [Entry], uid: uid_t, gid: gid_t,
    cancellation: CancellationToken? = nil
  ) throws {
    try validate(entries)
    let volume = try GuestVolume(destination)
    guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
      throw MisoError.invalid("Tar destination must be empty")
    }
    var directories = Set<String>()
    for entry in entries {
      var parts = entry.path.split(separator: "/")
      if entry.kind != S_IFDIR { parts = parts.dropLast() }
      while !parts.isEmpty {
        directories.insert(parts.joined(separator: "/"))
        parts = parts.dropLast()
      }
    }
    for relative in directories.sorted(by: { $0.count < $1.count }) {
      try SafeFile.makeDirectory(volume.path(relative))
    }
    var index = 0
    try read(source, cancellation: cancellation) { entry, archive in
      guard index < entries.count, entry == entries[index] else {
        throw MisoError.invalid("Tar contents changed after inspection")
      }
      index += 1
      let path = try volume.path(entry.path)
      if entry.kind == S_IFREG && entry.hardlink == nil {
        let file = try SafeFile.create(path)
        defer { try? file.close() }
        var remaining = entry.bytes
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while remaining > 0 {
          try cancellation?.check()
          let count = archive_read_data(archive, &buffer, min(buffer.count, Int(remaining)))
          guard count > 0, count <= remaining else {
            throw MisoError.invalid("Truncated tar payload")
          }
          try file.write(contentsOf: Data(buffer.prefix(count)))
          remaining -= Int64(count)
        }
        guard fchown(file.fileDescriptor, uid, gid) == 0,
          fchmod(file.fileDescriptor, entry.mode) == 0
        else { throw MisoError.system("Set tar payload ownership", errno) }
        try file.synchronize()
      }
    }
    guard index == entries.count else { throw MisoError.invalid("Incomplete tar payload") }
    for entry in entries {
      if let hardlink = entry.hardlink {
        guard Darwin.link(try volume.path(hardlink).path, try volume.path(entry.path).path) == 0
        else {
          throw MisoError.system("Create tar hardlink", errno)
        }
      }
    }
    for entry in entries where entry.kind == S_IFLNK {
      let path = try volume.path(entry.path)
      guard let link = entry.link, symlink(link, path.path) == 0, lchown(path.path, uid, gid) == 0,
        lchmod(path.path, entry.mode) == 0
      else { throw MisoError.system("Create tar symbolic link", errno) }
    }
    let modes = Dictionary(
      uniqueKeysWithValues: entries.filter { $0.kind == S_IFDIR }.map { ($0.path, $0.mode) })
    for relative in directories.sorted(by: { $0.count > $1.count }) {
      let path = try volume.path(relative)
      guard chown(path.path, uid, gid) == 0, chmod(path.path, modes[relative] ?? 0o755) == 0 else {
        throw MisoError.system("Set tar directory ownership", errno)
      }
    }
  }

  private static func read(
    _ source: URL, cancellation: CancellationToken?, body: (Entry, OpaquePointer) throws -> Void
  ) throws {
    guard let locale = newlocale(LC_CTYPE_MASK, "UTF-8", nil) else {
      throw MisoError.system("Create UTF-8 archive locale", errno)
    }
    guard let previousLocale = uselocale(locale) else {
      let error = errno
      freelocale(locale)
      throw MisoError.system("Select UTF-8 archive locale", error)
    }
    defer {
      uselocale(previousLocale)
      freelocale(locale)
    }
    guard (3_000_000..<4_000_000).contains(archive_version_number()) else {
      throw MisoError.unsupported("system archive ABI")
    }
    let file = try SafeFile.openRegular(source)
    defer { try? file.close() }
    guard let reader = archive_read_new() else { throw MisoError.invalid("Allocate tar reader") }
    defer { archive_read_free(reader) }
    guard archive_read_support_filter_gzip(reader) == ARCHIVE_OK,
      archive_read_support_filter_none(reader) == ARCHIVE_OK,
      archive_read_support_format_tar(reader) == ARCHIVE_OK,
      archive_read_open_fd(reader, file.fileDescriptor, 1 << 20) == ARCHIVE_OK
    else { throw MisoError.invalid("Open tar archive") }
    var header: OpaquePointer?
    var total: Int64 = 0
    var count = 0
    while true {
      try cancellation?.check()
      let status = archive_read_next_header(reader, &header)
      if status == ARCHIVE_EOF { break }
      guard status == ARCHIVE_OK else {
        let detail =
          archive_error_string(reader).map { String(cString: $0) } ?? "Unknown archive error"
        throw MisoError.invalid("Read tar header (status \(status)): \(detail)")
      }
      guard let header, let rawPath = archive_entry_pathname(header),
        let original = String(validatingCString: rawPath)
      else { throw MisoError.invalid("Tar header has no valid UTF-8 path") }
      var hardlink = archive_entry_hardlink(header).flatMap { String(validatingCString: $0) }
      if hardlink?.hasPrefix("./") == true { hardlink?.removeFirst(2) }
      let rawKind = UInt16(archive_entry_filetype(header))
      guard hardlink == nil || rawKind == 0 || rawKind == S_IFREG else {
        throw MisoError.invalid("Invalid hardlink file type")
      }
      let kind = hardlink == nil ? rawKind : UInt16(S_IFREG)
      var path = original
      if path.hasPrefix("./") { path.removeFirst(2) }
      if path.hasSuffix("/") { path.removeLast() }
      if ["", "."].contains(path), kind == S_IFDIR { continue }
      _ = try SafeFile.relativePath(path)
      let mode = UInt16(archive_entry_perm(header))
      let size = archive_entry_size(header)
      guard [S_IFREG, S_IFDIR, S_IFLNK].contains(kind), mode & 0o7000 == 0,
        size >= 0, size <= 8 << 30, total <= (8 << 30) - size, count < 100_000,
        kind == S_IFREG || size == 0
      else { throw MisoError.invalid("Unsafe tar payload metadata") }
      total += size
      count += 1
      let link = archive_entry_symlink(header).flatMap { String(validatingCString: $0) }
      guard (kind == S_IFLNK) == (link != nil) else {
        throw MisoError.invalid("Missing tar symlink target")
      }
      try body(
        Entry(path: path, kind: kind, mode: mode, bytes: size, link: link, hardlink: hardlink),
        reader)
      guard archive_read_data_skip(reader) == ARCHIVE_OK else {
        throw MisoError.invalid("Truncated tar entry")
      }
    }
    guard archive_read_close(reader) == ARCHIVE_OK else {
      throw MisoError.invalid("Close tar archive")
    }
  }
}

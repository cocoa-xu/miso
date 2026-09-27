import Darwin
import Foundation
import ZIPFoundation

enum ZIPPayload {
  static func extract(
    _ source: URL, to output: URL, maximumBytes: UInt64 = 8 << 30,
    cancellation: CancellationToken? = nil
  ) throws {
    guard (1...(8 << 30)).contains(maximumBytes) else {
      throw MisoError.invalid("Invalid ZIP extraction limit")
    }
    let handle = try SafeFile.openRegular(source)
    defer { try? handle.close() }
    let identity = try FileMetadata.inspect(source)
    let directory = try ZIPDirectory(handle)
    let archive = try Archive(url: source, accessMode: .read)
    var entries: [TarPayload.Entry] = []
    var originals: [String: Entry] = [:]
    var total: UInt64 = 0
    for entry in archive {
      try cancellation?.check()
      guard let rawMode = directory.fileModes[entry.path],
        entry.uncompressedSize <= maximumBytes - total
      else { throw MisoError.invalid("ZIP payload exceeds its directory or size bounds") }
      total += entry.uncompressedSize
      var path = entry.path
      if path.hasSuffix("/") { path.removeLast() }
      _ = try SafeFile.relativePath(path)
      let kind: UInt16
      switch entry.type {
      case .file: kind = UInt16(S_IFREG)
      case .directory: kind = UInt16(S_IFDIR)
      case .symlink: kind = UInt16(S_IFLNK)
      }
      guard originals.updateValue(entry, forKey: path) == nil,
        rawMode & 0o7000 == 0,
        rawMode & UInt32(S_IFMT) == 0 || rawMode & UInt32(S_IFMT) == kind,
        kind != S_IFDIR || entry.uncompressedSize == 0
      else { throw MisoError.invalid("Unsafe ZIP entry metadata") }
      let mode = rawMode == 0 ? (kind == S_IFREG ? UInt16(0o644) : 0o755) : UInt16(rawMode & 0o777)
      var link: String?
      if kind == S_IFLNK {
        guard entry.uncompressedSize > 0, entry.uncompressedSize <= 4096 else {
          throw MisoError.invalid("Invalid ZIP link size")
        }
        var data = Data()
        let checksum = try archive.extract(entry) { chunk in
          try cancellation?.check()
          guard chunk.count <= Int(entry.uncompressedSize) - data.count else {
            throw MisoError.invalid("ZIP link exceeds its declared size")
          }
          data.append(chunk)
        }
        guard checksum == entry.checksum, data.count == entry.uncompressedSize,
          let value = String(data: data, encoding: .utf8), !value.contains("\0")
        else { throw MisoError.invalid("Invalid ZIP link payload") }
        link = value
      }
      entries.append(
        .init(
          path: path, kind: kind, mode: mode,
          bytes: kind == S_IFREG ? Int64(entry.uncompressedSize) : 0, link: link))
    }
    guard entries.count == directory.fileModes.count else {
      throw MisoError.invalid("ZIP payload directory differs from entries")
    }
    try TarPayload.validate(entries)
    try SafeFile.makeDirectory(output)
    let volume = try GuestVolume(output)
    var directories = Set<String>()
    for entry in entries {
      var parts = entry.path.split(separator: "/")
      if entry.kind != S_IFDIR { parts = parts.dropLast() }
      while !parts.isEmpty {
        directories.insert(parts.joined(separator: "/"))
        parts = parts.dropLast()
      }
    }
    for path in directories.sorted(by: { $0.count < $1.count }) {
      try SafeFile.makeDirectory(volume.path(path))
    }
    for entry in entries where entry.kind == S_IFREG {
      try cancellation?.check()
      guard let original = originals[entry.path] else {
        throw MisoError.invalid("ZIP entry disappeared")
      }
      let file = try SafeFile.create(volume.path(entry.path))
      defer { try? file.close() }
      var remaining = entry.bytes
      let checksum = try archive.extract(original, bufferSize: 1 << 20) { data in
        try cancellation?.check()
        guard data.count <= remaining else {
          throw MisoError.invalid("ZIP entry exceeds its declared size")
        }
        try file.write(contentsOf: data)
        remaining -= Int64(data.count)
      }
      guard remaining == 0, checksum == original.checksum else {
        throw MisoError.invalid("ZIP entry checksum or size mismatch")
      }
      guard fchmod(file.fileDescriptor, entry.mode) == 0 else {
        throw MisoError.system("Set ZIP file mode", errno)
      }
      try file.synchronize()
    }
    for entry in entries where entry.kind == S_IFLNK {
      let path = try volume.path(entry.path)
      guard let link = entry.link, symlink(link, path.path) == 0,
        lchmod(path.path, entry.mode) == 0
      else { throw MisoError.system("Create ZIP symbolic link", errno) }
    }
    let modes = Dictionary(
      uniqueKeysWithValues: entries.filter { $0.kind == S_IFDIR }.map { ($0.path, $0.mode) })
    for path in directories.sorted(by: { $0.count > $1.count }) {
      guard chmod(try volume.path(path).path, modes[path] ?? 0o755) == 0 else {
        throw MisoError.system("Set ZIP directory mode", errno)
      }
    }
    let current = try FileMetadata.inspect(source)
    guard current.st_ino == identity.st_ino, current.st_dev == identity.st_dev,
      current.st_size == identity.st_size,
      current.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
      current.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
      current.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec,
      current.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec
    else { throw MisoError.invalid("ZIP source changed during extraction") }
  }
}

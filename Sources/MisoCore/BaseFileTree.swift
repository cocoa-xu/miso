import Darwin
import Foundation

enum BaseFileTree {
  static func inventory(
    _ volume: GuestVolume, path: String, cancellation: CancellationToken? = nil
  ) throws -> [BaseInputArchive.Entry] {
    try BaseInputArchive.inventory(
      volume.directory(path).url, guestPath: path,
      cancellation: cancellation)
  }

  static func requireOwnership(
    _ root: URL, entries: [BaseInputArchive.Entry], uid: uid_t, gid: gid_t
  ) throws {
    for entry in entries {
      let path =
        entry.path == "."
        ? root : root.appendingPathComponent(try SafeFile.relativePath(entry.path))
      let info = try FileMetadata.inspect(path)
      guard info.st_uid == uid, info.st_gid == gid else {
        throw MisoError.invalid("Payload ownership mismatch: \(entry.path)")
      }
    }
  }

  static func copy(
    _ source: URL, to destination: URL, entries: [BaseInputArchive.Entry], uid: uid_t, gid: gid_t,
    cancellation: CancellationToken?
  ) throws {
    guard entries.first?.path == ".", entries.first?.kind == "directory" else {
      throw MisoError.invalid("Expected a directory payload")
    }
    guard Set(entries.map(\.path)).count == entries.count else {
      throw MisoError.invalid("Duplicate tree entry")
    }
    for entry in entries {
      if entry.path != "." { _ = try SafeFile.relativePath(entry.path) }
      guard ["directory", "file", "symlink"].contains(entry.kind), entry.mode & ~0o777 == 0 else {
        throw MisoError.invalid("Unsupported tree entry")
      }
      if entry.kind == "file" {
        guard entry.bytes != nil, let hash = entry.sha256 else {
          throw MisoError.invalid("Missing tree file identity")
        }
        try SafeFile.validateSHA256(hash)
      }
      if entry.kind == "symlink" {
        guard let link = entry.link else { throw MisoError.invalid("Missing tree link target") }
        _ = try SafeFile.relativeLink(link, at: entry.path)
      }
    }
    for entry in entries.filter({ $0.kind == "directory" }).sorted(by: {
      $0.path.count < $1.path.count
    }) {
      try SafeFile.makeDirectory(
        entry.path == "." ? destination : destination.appendingPathComponent(entry.path))
    }
    let volume = try GuestVolume(destination)
    for entry in entries where entry.kind != "directory" {
      try cancellation?.check()
      let path = try volume.path(entry.path)
      if entry.kind == "file" {
        let origin = source.appendingPathComponent(entry.path)
        if entry.bytes == 0 {
          try SafeFile.writeNew(Data(), to: path)
        } else {
          try Artifacts.copy(
            origin, to: path, maximumBytes: entry.bytes!, cancellation: cancellation)
        }
        guard try SafeFile.sha256(path) == entry.sha256, chown(path.path, uid, gid) == 0,
          chmod(path.path, entry.mode) == 0
        else { throw MisoError.invalid("Copied payload differs from inventory") }
      } else if entry.kind == "symlink", let link = entry.link {
        _ = try SafeFile.relativeLink(link, at: entry.path)
        guard symlink(link, path.path) == 0, lchown(path.path, uid, gid) == 0,
          lchmod(path.path, entry.mode) == 0
        else { throw MisoError.system("Copy payload link", errno) }
      } else {
        throw MisoError.invalid("Unsupported payload entry")
      }
    }
    for entry in entries.filter({ $0.kind == "directory" }).sorted(by: {
      $0.path.count > $1.path.count
    }) {
      let path = entry.path == "." ? destination : try volume.path(entry.path)
      guard chown(path.path, uid, gid) == 0, chmod(path.path, entry.mode) == 0 else {
        throw MisoError.system("Set payload directory ownership", errno)
      }
    }
    guard try BaseInputArchive.inventory(source, cancellation: cancellation) == entries,
      try BaseInputArchive.inventory(destination, cancellation: cancellation) == entries
    else {
      throw MisoError.invalid("Payload changed during installation")
    }
  }
}

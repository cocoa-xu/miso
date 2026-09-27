import Darwin
import Foundation

enum GuestCleanup {
  static func removeDirectory(
    _ relative: String, volume: GuestVolume, uid: uid_t, gid: gid_t,
    rootOwner: (uid: uid_t, gid: gid_t)? = nil,
    cancellation: CancellationToken? = nil
  ) throws -> Int {
    _ = try SafeFile.relativePath(relative)
    guard relative.contains("/") else { throw MisoError.invalid("Cleanup scope is too broad") }
    guard try volume.contains(relative) else { return 0 }
    let directory = try volume.directory(relative)
    let entries = try BaseFileTree.inventory(volume, path: relative, cancellation: cancellation)
    let identities = try Dictionary(
      uniqueKeysWithValues: entries.map { entry in
        let url =
          entry.path == "." ? directory.url : directory.url.appendingPathComponent(entry.path)
        let info = try FileMetadata.inspect(url)
        let owner = entry.path == "." ? rootOwner ?? (uid, gid) : (uid, gid)
        guard info.st_uid == owner.0, info.st_gid == owner.1 else {
          throw MisoError.invalid("Cleanup ownership mismatch: \(relative)/\(entry.path)")
        }
        return (entry.path, info)
      })
    for entry in entries.sorted(by: { $0.path.count > $1.path.count }) {
      try cancellation?.check()
      let path = entry.path == "." ? relative : relative + "/" + entry.path
      let url = try volume.path(path, allowLeafLink: true)
      let parent = open(
        url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard parent >= 0 else { throw MisoError.system("Open cleanup parent", errno) }
      defer { close(parent) }
      var current = stat()
      guard let expected = identities[entry.path],
        fstatat(parent, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
        current.st_uid == expected.st_uid, current.st_gid == expected.st_gid,
        current.st_mode == expected.st_mode
      else { throw MisoError.invalid("Cleanup entry identity changed: \(path)") }
      guard
        unlinkat(parent, url.lastPathComponent, entry.kind == "directory" ? AT_REMOVEDIR : 0) == 0
      else {
        throw MisoError.system("Remove guest cache entry", errno)
      }
    }
    guard !(try volume.contains(relative)) else { throw MisoError.invalid("Guest cache remains") }
    return entries.count
  }
}

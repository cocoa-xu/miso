import Darwin
import Foundation

struct RestoreArchive {
  let url: URL
  private let identity: (device: dev_t, inode: ino_t)?

  var downloaded: Bool { identity != nil }

  static func acquire(
    _ source: URL, workspace: URL, cancellation: CancellationToken? = nil,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> Self {
    if source.isFileURL { return Self(url: source, identity: nil) }
    try HTTPFile.validate(source, maximumBytes: 32 << 30, appleRestore: true)
    let downloads = workspace.appendingPathComponent("downloads")
    try SafeFile.makeDirectory(downloads)
    let destination = downloads.appendingPathComponent("restore.ipsw")
    try await HTTPFile.restoreArchive(
      source, to: destination, cancellation: cancellation, configuration: configuration)
    let file = try SafeFile.openRegular(destination)
    defer { try? file.close() }
    var info = stat()
    guard fstat(file.fileDescriptor, &info) == 0 else {
      throw MisoError.system("Inspect downloaded IPSW", errno)
    }
    return Self(url: destination, identity: (info.st_dev, info.st_ino))
  }

  func removeDownload(keepDownloads: Bool) throws -> Bool {
    guard !keepDownloads, let identity else { return false }
    let parent = try SafeFile.openDirectory(url.deletingLastPathComponent())
    defer { close(parent) }
    var info = stat()
    guard fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw MisoError.system("Inspect downloaded IPSW before removal", errno)
    }
    guard info.st_mode & S_IFMT == S_IFREG,
      info.st_dev == identity.device, info.st_ino == identity.inode
    else { throw MisoError.invalid("Downloaded IPSW was replaced; refusing to remove it") }
    guard unlinkat(parent, url.lastPathComponent, 0) == 0 else {
      throw MisoError.system("Remove downloaded IPSW", errno)
    }
    return true
  }
}

import Darwin
import Foundation

enum BaseStageWorkspace {
  static func prune(_ stage: URL, image: Bool, journal: ExecutionJournal) throws {
    guard stage.deletingLastPathComponent().path == journal.output.path,
      try FileMetadata.inspect(stage).st_uid == geteuid()
    else { throw MisoError.invalid("Cleanup stage is not owned by this build") }
    let volume = try GuestVolume(stage)
    let record = try JSON.read(ExecutionJournal.Record.self, from: volume.path("journal.json"))
    guard record.status == .complete, !record.vmStarted else {
      throw MisoError.invalid("Only completed offline stages can be pruned")
    }
    try requireUnmounted(stage)
    try DiskImageSession(
      image: volume.path("bundle/disk.img"), readOnly: true, journal: journal
    ).requireDetached()
    if try volume.contains("execution-root") {
      let root = try volume.directory("execution-root").url
      let identity = try FileMetadata.inspect(root)
      guard identity.st_uid == geteuid() else {
        throw MisoError.invalid("Execution view owner changed")
      }
      var walkError: (any Error)?
      guard
        let walk = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: nil,
          errorHandler: { _, error in
            walkError = error
            return false
          })
      else {
        throw MisoError.invalid("Cannot inspect execution view")
      }
      var count = 0
      for case let path as URL in walk {
        try journal.cancellation.check()
        let info = try FileMetadata.inspect(path)
        count += 1
        guard count < 2_000_000, info.st_dev == volume.device,
          [S_IFDIR, S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT)
        else { throw MisoError.invalid("Execution view contains a mount or special file") }
      }
      if let walkError { throw walkError }
      try requireUnmounted(stage)
      guard try FileMetadata.inspect(root).st_ino == identity.st_ino else {
        throw MisoError.invalid("Execution view identity changed")
      }
      try FileManager.default.removeItem(at: root)
    }
    if image {
      let path = try volume.path("bundle/disk.img")
      let info = try FileMetadata.inspect(path)
      guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, unlink(path.path) == 0 else {
        throw MisoError.invalid("Cannot remove owned intermediate image")
      }
    }
  }

  static func requireUnmounted(_ root: URL) throws {
    var mounts: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&mounts, MNT_NOWAIT)
    guard count > 0, let mounts else { throw MisoError.system("Inspect workspace mounts", errno) }
    for index in 0..<Int(count) {
      let path = withUnsafePointer(to: &mounts[index].f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      guard path != root.path, !path.hasPrefix(root.path + "/") else {
        throw MisoError.invalid("Build workspace still contains a mounted filesystem")
      }
    }
  }
}

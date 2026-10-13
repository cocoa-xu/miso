import Foundation

final class ImageMountGroup {
  private let session: DiskImageSession
  private let journal: ExecutionJournal
  private var volumes: [(APFSTopology.Volume, URL, String)] = []

  init(session: DiskImageSession, journal: ExecutionJournal) {
    self.session = session
    self.journal = journal
  }

  func mount(
    _ volume: APFSTopology.Volume, name: String, readOnly: Bool, at root: URL,
    systemOverlay: ImageMounts.SystemOverlay? = nil
  ) throws -> GuestVolume {
    volumes.append((volume, root, name))
    return try ImageMounts.mount(
      volume, session: session, journal: journal, name: name, readOnly: readOnly,
      at: root, restricted: true, systemOverlay: systemOverlay)
  }

  func withCleanup<T>(_ body: () throws -> T) throws -> T {
    do {
      let result = try body()
      try unmount()
      return result
    } catch {
      let original = error
      do { try unmount() } catch {
        throw MisoError.invalid(
          "\(original.localizedDescription); volume cleanup failed: \(error.localizedDescription)")
      }
      throw original
    }
  }

  private func unmount() throws {
    while let (volume, root, name) = volumes.last {
      func refresh() throws -> [ImageMounts.Mount] {
        guard
          try session.containers(cleanup: true).flatMap(\.volumes).contains(where: {
            $0.identifier == volume.identifier && $0.device == volume.device
          })
        else { throw MisoError.invalid("Owned volume disappeared during unmount") }
        return try ImageMounts.mounts()
      }
      let mounts = try refresh()
      if mounts.contains(where: { $0.device == "/dev/" + volume.device }) {
        try ImageMounts.verifyMounts(mounts, volume: volume, mountPoint: root.path)
        try journal.run(
          "unmount-" + name,
          NativeCommand(.disks, arguments: ["unmount", volume.device], timeout: 120), cleanup: true)
        try ImageMounts.verifyMounts(refresh(), volume: volume, mountPoint: nil)
      }
      volumes.removeLast()
    }
  }

}

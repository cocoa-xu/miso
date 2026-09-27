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
      try session.verifyOwnership(cleanup: true)
      let entries = session.attachment?.entities.filter { $0.device == "/dev/" + volume.device }
      guard let entries, entries.count == 1 else {
        throw MisoError.invalid("Owned volume disappeared before unmount")
      }
      if entries[0].mountPoint != nil {
        try ImageMounts.verifyAttachment(session.attachment, volume: volume, mountPoint: root.path)
        try journal.run(
          "unmount-" + name,
          NativeCommand(.disks, arguments: ["unmount", volume.device], timeout: 120), cleanup: true)
        try session.verifyOwnership(cleanup: true)
        try ImageMounts.verifyAttachment(session.attachment, volume: volume, mountPoint: nil)
      }
      volumes.removeLast()
    }
  }
}

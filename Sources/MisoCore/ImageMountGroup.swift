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
      func refresh() throws -> DiskImageAttachment? {
        try session.verifyOwnership(cleanup: true)
        return session.attachment
      }
      let entry = try Self.ownedVolume(volume, refresh: refresh)
      if entry.mountPoint != nil {
        try ImageMounts.verifyAttachment(session.attachment, volume: volume, mountPoint: root.path)
        try journal.run(
          "unmount-" + name,
          NativeCommand(.disks, arguments: ["unmount", volume.device], timeout: 120), cleanup: true)
        _ = try Self.ownedVolume(volume, refresh: refresh)
        try ImageMounts.verifyAttachment(session.attachment, volume: volume, mountPoint: nil)
      }
      volumes.removeLast()
    }
  }

  static func ownedVolume(
    _ volume: APFSTopology.Volume,
    refresh: () throws -> DiskImageAttachment?,
    pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }
  ) throws -> DiskImageAttachment.Entity {
    for attempt in 0..<3 {
      guard let attachment = try refresh() else {
        throw MisoError.invalid("Owned image disappeared during unmount")
      }
      let entries = attachment.entities.filter { $0.device == "/dev/" + volume.device }
      guard entries.count <= 1 else {
        throw MisoError.invalid("Ambiguous owned volume during unmount")
      }
      if let entry = entries.first { return entry }
      if attempt < 2 { pause() }
    }
    throw MisoError.invalid("Owned volume disappeared during unmount")
  }
}

import Darwin
import Foundation

public struct DiskImageAttachment: Codable, Sendable {
  public struct Entity: Codable, Sendable {
    public let device: String
    public let contentHint: String?
    public let mountPoint: String?
    enum CodingKeys: String, CodingKey {
      case device = "dev-entry"
      case contentHint = "content-hint"
      case mountPoint = "mount-point"
    }
  }

  public let entities: [Entity]
  enum CodingKeys: String, CodingKey { case entities = "system-entities" }

  public func wholeDevice(requireGPT: Bool) throws -> String {
    let wholes = entities.filter {
      $0.device.range(of: #"\A/dev/disk[0-9]+\z"#, options: .regularExpression) != nil
        && (!requireGPT || $0.contentHint == "GUID_partition_scheme")
        && $0.contentHint?.uppercased() != "EF57347C-0000-11AA-AA11-00306543ECAC"
    }
    guard wholes.count == 1, let whole = wholes.first else {
      throw MisoError.invalid("Expected one owned whole-disk attachment")
    }
    guard
      entities.allSatisfy({
        $0.device.range(of: #"\A/dev/disk[0-9]+(?:s[0-9]+)*\z"#, options: .regularExpression) != nil
      })
    else {
      throw MisoError.invalid("Invalid attached device node")
    }
    return whole.device
  }
}

public struct APFSTopology: Codable, Sendable {
  public struct Store: Codable, Sendable {
    public let device: String
    enum CodingKeys: String, CodingKey { case device = "DeviceIdentifier" }
  }

  public struct Volume: Codable, Sendable {
    public let device: String
    public let identifier: UUID
    public let roles: [String]
    public let name: String?
    public let mountPoint: String?
    public let encrypted: Bool?
    public let capacityInUse: UInt64?

    public init(
      device: String, identifier: UUID, roles: [String], name: String?, mountPoint: String?,
      encrypted: Bool? = nil, capacityInUse: UInt64? = nil
    ) {
      self.device = device
      self.identifier = identifier
      self.roles = roles
      self.name = name
      self.mountPoint = mountPoint
      self.encrypted = encrypted
      self.capacityInUse = capacityInUse
    }
    enum CodingKeys: String, CodingKey {
      case device = "DeviceIdentifier"
      case identifier = "APFSVolumeUUID"
      case roles = "Roles"
      case name = "Name"
      case mountPoint = "MountPoint"
      case encrypted = "Encryption"
      case capacityInUse = "CapacityInUse"
    }
  }

  public struct Container: Codable, Sendable {
    public let device: String
    public let identifier: UUID
    public let stores: [Store]
    public let volumes: [Volume]
    enum CodingKeys: String, CodingKey {
      case device = "ContainerReference"
      case identifier = "APFSContainerUUID"
      case stores = "PhysicalStores"
      case volumes = "Volumes"
    }

    public func volume(role: String) throws -> Volume {
      let matches = volumes.filter { $0.roles == [role] }
      guard matches.count == 1, let volume = matches.first else {
        throw MisoError.invalid("Missing or ambiguous APFS volume role: \(role)")
      }
      return volume
    }
  }

  public let containers: [Container]
  enum CodingKeys: String, CodingKey { case containers = "Containers" }

  public func owned(by attachment: DiskImageAttachment) throws -> [Container] {
    let nodes = Set(attachment.entities.map { String($0.device.dropFirst(5)) })
    var seen = Set<UUID>()
    var devices = Set<String>()
    return try containers.filter { container in
      let membership = container.stores.map { nodes.contains($0.device) }
      guard membership.contains(true) else { return false }
      guard membership.allSatisfy({ $0 }), container.stores.count == 1,
        seen.insert(container.identifier).inserted, devices.insert(container.device).inserted,
        container.device.range(of: #"\Adisk[0-9]+\z"#, options: .regularExpression) != nil,
        Set(container.volumes.map(\.identifier)).count == container.volumes.count,
        Set(container.volumes.map(\.device)).count == container.volumes.count
      else {
        throw MisoError.invalid("Ambiguous or mixed-ownership APFS container")
      }
      for volume in container.volumes {
        _ = try APFSIdentity.rawVolume(volume.device)
        guard volume.device.hasPrefix(container.device + "s") else {
          throw MisoError.invalid("APFS volume is outside its container")
        }
      }
      return true
    }
  }
}

public final class DiskImageSession {
  private struct ImageInfo: Decodable {
    struct Image: Decodable {
      let path: String?
      let entities: [DiskImageAttachment.Entity]
      let writable: Bool?
      enum CodingKeys: String, CodingKey {
        case path = "image-path"
        case entities = "system-entities"
        case writable = "writeable"
      }
    }
    let images: [Image]
  }

  public let image: URL
  public let readOnly: Bool
  public private(set) var attachment: DiskImageAttachment?
  private let journal: ExecutionJournal
  private let handle: FileHandle
  private let originalIdentity: (dev_t, ino_t)
  private var whole: String?
  private var attachmentAttempted = false
  private let forceReadOnlyDetach: Bool

  public init(
    image: URL, readOnly: Bool, journal: ExecutionJournal, forceReadOnlyDetach: Bool = false
  ) throws {
    guard journal.record.status == .running else {
      throw MisoError.invalid("Image sessions require an active operation")
    }
    try journal.cancellation.check()
    guard image.isFileURL, image.path == image.standardizedFileURL.path,
      image.path == image.resolvingSymlinksInPath().path
    else {
      throw MisoError.invalid("Image path must be canonical")
    }
    if !readOnly {
      guard image.path.hasPrefix(journal.output.path + "/") else {
        throw MisoError.invalid("Writable images must belong to this operation's output")
      }
    }
    guard !forceReadOnlyDetach || (readOnly && image.path.hasPrefix(journal.output.path + "/"))
    else {
      throw MisoError.invalid("Forced detach requires an owned read-only image")
    }
    self.forceReadOnlyDetach = forceReadOnlyDetach
    self.image = image
    self.readOnly = readOnly
    self.journal = journal
    handle = try SafeFile.openRegular(image, writable: !readOnly)
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0 else {
      throw MisoError.system("Inspect image identity", errno)
    }
    originalIdentity = (info.st_dev, info.st_ino)
    if readOnly && flock(handle.fileDescriptor, LOCK_SH | LOCK_NB) != 0 {
      throw MisoError.system("Lock image", errno)
    }
  }

  deinit { try? handle.close() }

  func requireDetached() throws {
    guard !attachmentAttempted, whole == nil, try matchingImages().isEmpty else {
      throw MisoError.invalid("Image must be detached")
    }
  }

  func withDetachedFile<T>(_ body: (FileHandle) throws -> T) throws -> T {
    guard !readOnly, journal.record.status == .running else {
      throw MisoError.invalid("Cannot modify an inactive or read-only image")
    }
    try journal.cancellation.check()
    try requireDetached()
    let result = try body(handle)
    try handle.synchronize()
    try checkFileIdentity()
    return result
  }

  public func withAttachment<T>(
    requireGPT: Bool = true, mountPoint: URL? = nil, existingEmptyMountPoint: Bool = false,
    _ body: (DiskImageSession) throws -> T
  ) throws -> T {
    do {
      try attach(
        requireGPT: requireGPT, mountPoint: mountPoint,
        existingEmptyMountPoint: existingEmptyMountPoint)
      let result = try body(self)
      try detach()
      return result
    } catch {
      let original = error
      do { try detach() } catch {
        throw MisoError.invalid(
          "\(original.localizedDescription); attachment cleanup failed: \(error.localizedDescription)"
        )
      }
      throw original
    }
  }

  private func checkFileIdentity() throws {
    var info = stat()
    guard lstat(image.path, &info) == 0 else { throw MisoError.system("Inspect image path", errno) }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_dev == originalIdentity.0,
      info.st_ino == originalIdentity.1
    else {
      throw MisoError.invalid("Image file identity changed")
    }
  }

  private func matchingImages(cleanup: Bool = false) throws -> [ImageInfo.Image] {
    try checkFileIdentity()
    let info = try journal.plist(
      ImageInfo.self, name: "image-ownership",
      command: NativeCommand(.diskImages, arguments: ["info", "-plist"], timeout: 60),
      cleanup: cleanup)
    return info.images.filter { $0.path == image.path }
  }

  private func attach(requireGPT: Bool, mountPoint: URL?, existingEmptyMountPoint: Bool) throws {
    guard !attachmentAttempted, whole == nil, try matchingImages().isEmpty else {
      throw MisoError.invalid("Image is already attached or this session was used")
    }
    var arguments = ["attach", "-nobrowse", "-plist"]
    if readOnly { arguments += ["-readonly", "-owners", "on"] }
    if let mountPoint {
      guard readOnly, mountPoint.isFileURL, mountPoint.path == mountPoint.standardizedFileURL.path,
        mountPoint.path.hasPrefix(journal.output.path + "/")
      else {
        throw MisoError.invalid(
          "Automatic mounts require a read-only image and an owned mount point")
      }
      if existingEmptyMountPoint {
        _ = try GuestVolume(mountPoint)
        guard try FileManager.default.contentsOfDirectory(atPath: mountPoint.path).isEmpty else {
          throw MisoError.invalid("Existing image mount point must be empty")
        }
      } else {
        try SafeFile.makeDirectory(mountPoint)
      }
      arguments += ["-mountpoint", mountPoint.path]
    } else {
      arguments += ["-nomount"]
    }
    arguments.append(image.path)
    attachmentAttempted = true
    let attached = try journal.plist(
      DiskImageAttachment.self, name: "attach-image",
      command: NativeCommand(.diskImages, arguments: arguments, timeout: 180))
    whole = try attached.wholeDevice(requireGPT: requireGPT)
    attachment = attached
    try verifyOwnership()
    if let mountPoint {
      var info = statfs()
      guard attached.entities.filter({ $0.mountPoint == mountPoint.path }).count == 1,
        statfs(mountPoint.path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) != 0
      else {
        throw MisoError.invalid("Mounted image is not read-only at the requested location")
      }
    }
  }

  public func verifyOwnership() throws {
    guard let whole else { throw MisoError.invalid("Image is not attached") }
    let matches = try matchingImages()
    guard matches.count == 1, let match = matches.first,
      match.entities.contains(where: { $0.device == whole })
    else {
      throw MisoError.invalid("Image attachment ownership changed")
    }
    guard match.writable == !readOnly else {
      throw MisoError.invalid("Backing image attachment access differs from requested access")
    }
    attachment = DiskImageAttachment(entities: match.entities)
  }

  public func containers() throws -> [APFSTopology.Container] {
    try verifyOwnership()
    guard let attachment else { throw MisoError.invalid("Missing image attachment") }
    let topology = try journal.plist(
      APFSTopology.self, name: "apfs-topology",
      command: NativeCommand(.disks, arguments: ["apfs", "list", "-plist"], timeout: 120))
    return try topology.owned(by: attachment)
  }

  public func detach() throws {
    guard attachmentAttempted else { return }
    let matches = try matchingImages(cleanup: true)
    if matches.isEmpty {
      whole = nil
      attachment = nil
      attachmentAttempted = false
      return
    }
    guard matches.count == 1, let match = matches.first else {
      throw MisoError.invalid("Ambiguous image attachment; refusing detach")
    }
    let current = DiskImageAttachment(entities: match.entities)
    let device: String
    if let whole {
      guard current.entities.contains(where: { $0.device == whole }) else {
        throw MisoError.invalid("Owned whole disk disappeared")
      }
      device = whole
    } else {
      device = try current.wholeDevice(
        requireGPT: current.entities.contains { $0.contentHint == "GUID_partition_scheme" })
    }
    try journal.run(
      "detach-image", NativeCommand(.diskImages, arguments: ["detach", device], timeout: 120),
      cleanup: true, expectedExitCodes: forceReadOnlyDetach ? [0, 16] : [0])
    if journal.record.commands.last?.result?.exitCode == 16 {
      let current = try matchingImages(cleanup: true)
      guard forceReadOnlyDetach, readOnly, current.count == 1, current[0].writable == false,
        current[0].entities.contains(where: { $0.device == device })
      else {
        throw MisoError.invalid("Read-only attachment identity changed before forced detach")
      }
      try journal.run(
        "detach-owned-readonly-image",
        NativeCommand(.diskImages, arguments: ["detach", "-force", device], timeout: 120),
        cleanup: true)
    }
    guard try matchingImages(cleanup: true).isEmpty else {
      throw MisoError.invalid("Image remains attached after detach")
    }
    whole = nil
    attachment = nil
    attachmentAttempted = false
  }
}

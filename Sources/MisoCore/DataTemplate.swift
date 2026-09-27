import CryptoKit
import Darwin
import Foundation

enum DataTemplate {
  static let receiptPath = "Library/Apple/System/Library/Receipts/com.apple.files.data-template"

  struct Receipt: Codable, Sendable {
    let entries: Int
    let regularFiles: Int
    let logicalBytes: UInt64
    let contentSHA256: String
    let metadataRepairs: Int
    let hostProvenanceAttributes: Int?
    let firmlinks: [String]
    let deferredFirmlinks: [String]
  }

  static func populate(
    system: GuestVolume, data: GuestVolume, profile: RestoreProfile,
    cancellation: CancellationToken
  ) throws -> Receipt {
    let version = try system.plist("System/Library/CoreServices/SystemVersion.plist")
    guard version["ProductVersion"] as? String == profile.release.version,
      version["ProductBuildVersion"] as? String == profile.release.build
    else { throw MisoError.invalid("Mounted System release differs from prepared profile") }
    let source = try system.path("System/Library/Templates/Data")
    let sourceInfo = try FileMetadata.inspect(source)
    guard sourceInfo.st_mode & S_IFMT == S_IFDIR, sourceInfo.st_dev == system.device else {
      throw MisoError.invalid("Data template is outside the sealed System")
    }
    let allowed = Set([".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"])
    for name in try FileManager.default.contentsOfDirectory(atPath: data.root.path) {
      let info = try FileMetadata.inspect(data.path(name))
      guard allowed.contains(name), info.st_mode & S_IFMT == S_IFDIR,
        info.st_dev == data.device
      else { throw MisoError.invalid("Data volume is not fresh") }
    }
    try FileMetadata.copyTree(
      system.directory("System/Library/Templates/Data"), to: data.directory(),
      cancellation: cancellation)
    let audit = try audit(source: source, destination: data, cancellation: cancellation)
    try data.mergePlist(
      receiptPath + ".plist",
      values: [
        "AdditionalInformation": [
          "SymlinkedDirectoryPatterns": [String](), "SymlinkedFilePatterns": [String](),
          "SystemBuild": profile.release.build, "SystemVersion": profile.release.version,
        ],
        "InstallDate": Date(), "InstallPrefixPath": "/", "InstallProcessName": "miso",
        "PackageGroups": ["com.apple.FindSystemFiles.pkg-group", "com.apple.OSTemplate.pkg-group"],
        "PackageIdentifier": "com.apple.files.data-template",
        "PackageVersion": profile.release.version,
      ])
    guard
      try SafeFile.sha256(data.path(receiptPath + ".bom"))
        == SafeFile.sha256(source.appendingPathComponent(receiptPath + ".bom"))
    else { throw MisoError.invalid("Data template BOM changed") }
    let links = try verifyFirmlinks(system: system, data: data, source: source, profile: profile)
    return Receipt(
      entries: audit.entries, regularFiles: audit.regularFiles, logicalBytes: audit.logicalBytes,
      contentSHA256: audit.contentSHA256, metadataRepairs: audit.metadataRepairs,
      hostProvenanceAttributes: audit.hostProvenanceAttributes,
      firmlinks: links.0, deferredFirmlinks: links.1)
  }

  static func audit(source: URL, destination: GuestVolume, cancellation: CancellationToken) throws
    -> Receipt
  {
    var entries: [(String, stat, String?)] = []
    try FileMetadata.walk(source) { relative, left in
      try cancellation.check()
      let target = try destination.path(relative, allowLeafLink: true)
      let right = try FileMetadata.inspect(target)
      guard left.st_mode & S_IFMT == right.st_mode & S_IFMT, right.st_dev == destination.device
      else {
        throw MisoError.invalid("Template entry type or device mismatch: \(relative)")
      }
      let origin = source.appendingPathComponent(relative)
      let checksum: String?
      switch left.st_mode & S_IFMT {
      case S_IFREG:
        checksum = try SafeFile.sha256(origin)
        guard left.st_size == right.st_size, try SafeFile.sha256(target) == checksum else {
          throw MisoError.invalid("Template content mismatch: \(relative)")
        }
      case S_IFLNK:
        guard
          try FileManager.default.destinationOfSymbolicLink(atPath: origin.path)
            == FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        else { throw MisoError.invalid("Template symbolic link mismatch: \(relative)") }
        checksum = nil
      case S_IFDIR: checksum = nil
      default: throw MisoError.invalid("Unsupported template entry: \(relative)")
      }
      entries.append((relative, left, checksum))
    }
    var repairs = 0
    for (relative, expected, _) in entries.sorted(by: {
      $0.0.split(separator: "/").count > $1.0.split(separator: "/").count
    }) {
      let target = try destination.path(relative, allowLeafLink: true)
      if !FileMetadata.equivalent(expected, try FileMetadata.inspect(target)) {
        try FileMetadata.repair(target, expected: expected)
        repairs += 1
      }
    }
    var content = SHA256()
    var files = 0
    var bytes: UInt64 = 0
    var provenance = 0
    for (relative, expected, checksum) in entries.sorted(by: { $0.0 < $1.0 }) {
      try cancellation.check()
      let origin = source.appendingPathComponent(relative)
      let target = try destination.path(relative, allowLeafLink: true)
      let actual = try FileMetadata.inspect(target)
      guard FileMetadata.equivalent(expected, actual),
        try FileMetadata.acl(origin) == FileMetadata.acl(target)
      else { throw MisoError.invalid("Template metadata mismatch: \(relative)") }
      if try FileMetadata.restoreAttributes(
        origin, to: target,
        ignoringCompression: (expected.st_flags | actual.st_flags) & UInt32(UF_COMPRESSED) != 0)
      {
        provenance += 1
      }
      if let checksum {
        guard try SafeFile.sha256(target) == checksum else {
          throw MisoError.invalid("Copied file changed during verification")
        }
        content.update(data: Data((relative + "\0" + checksum + "\n").utf8))
        files += 1
        bytes += UInt64(expected.st_size)
      }
    }
    let left = try FileMetadata.inspect(source)
    let right = try FileMetadata.inspect(destination.root)
    guard left.st_uid == right.st_uid, left.st_gid == right.st_gid, left.st_mode == right.st_mode
    else {
      throw MisoError.invalid("Copied root metadata mismatch")
    }
    return Receipt(
      entries: entries.count, regularFiles: files, logicalBytes: bytes,
      contentSHA256: content.finalize().map { String(format: "%02x", $0) }.joined(),
      metadataRepairs: repairs, hostProvenanceAttributes: provenance,
      firmlinks: [], deferredFirmlinks: [])
  }

  static func verifyFirmlinks(
    system: GuestVolume, data: GuestVolume, source: URL, profile: RestoreProfile
  )
    throws -> ([String], [String])
  {
    let content = try SafeFile.read(system.path("usr/share/firmlinks"), limit: 1 << 20)
    guard let text = String(data: content, encoding: .utf8) else {
      throw MisoError.invalid("Invalid firmlink list")
    }
    var verified: [String] = []
    var deferred: [String] = []
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 2, parts[0].hasPrefix("/"),
        (try? SafeFile.relativePath(String(parts[0].dropFirst()))) != nil
      else { throw MisoError.invalid("Invalid firmlink record") }
      let target = try data.path(parts[1])
      if parts[0] == "/AppleInternal",
        !FileManager.default.fileExists(atPath: source.appendingPathComponent(parts[1]).path)
      {
        continue
      }
      var left = stat()
      var right = stat()
      guard stat(target.path, &right) == 0, right.st_dev == data.device else {
        throw MisoError.invalid("Missing firmlink destination")
      }
      let origin = system.root.appendingPathComponent(String(parts[0].dropFirst()))
      if stat(origin.path, &left) != 0 {
        guard errno == ENOENT, profile.deferredFirmlinks.contains(parts[0]),
          parts[0] == "/" + parts[1], right.st_mode & S_IFMT == S_IFDIR
        else { throw MisoError.invalid("Missing firmlink source") }
        deferred.append(parts[0])
      } else {
        guard left.st_dev == right.st_dev, left.st_ino == right.st_ino else {
          throw MisoError.invalid("Firmlink does not resolve to Data: \(parts[0])")
        }
        verified.append(parts[0])
      }
    }
    return (verified, deferred)
  }
}

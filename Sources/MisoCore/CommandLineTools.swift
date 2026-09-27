import Darwin
import Foundation

enum CommandLineTools {
  static func requireGuestAccess(_ data: GuestVolume) throws {
    for relative in [
      PackageInventory.root + "/usr/bin",
      "Library/Apple/System/Library/Receipts",
    ] {
      var current = ""
      for component in relative.split(separator: "/") {
        current += (current.isEmpty ? "" : "/") + component
        let info = try FileMetadata.inspect(data.directory(current).url)
        guard info.st_mode & 0o005 == 0o005 else {
          throw MisoError.invalid("CLT directory is not guest-readable: \(current)")
        }
      }
    }
  }

  struct Package: Codable, Sendable {
    let filename: String
    let identifier: String
    let version: String
    let sha256: String
    let scriptsNotExecuted: [String: String]
  }

  struct Receipt: Codable, Sendable {
    let product: String
    let packages: [Package]
    let entries: Int
    let regularFiles: Int
    let compressedFiles: Int
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let sdk: String
    let manualIndexSHA256: String
  }

  struct Prepared {
    let packages: [Package]
    let entries: [String: PackageInventory.Entry]
    let expansions: [URL]
  }

  static func validateInputs(
    packages: URL, profile: RestoreProfile, cancellation: CancellationToken? = nil
  ) throws -> (source: GuestVolume, pins: [CLTPins.Package]) {
    let product = profile.commandLineTools.product
    guard let pins = CLTPins.packages[product] else { throw MisoError.unsupported("CLT product") }
    let source = try GuestVolume(packages)
    for pin in pins {
      try cancellation?.check()
      let handle = try SafeFile.openRegular(source.path(pin.filename))
      defer { try? handle.close() }
      guard try SafeFile.sha256(handle, cancellation: cancellation) == pin.sha256 else {
        throw MisoError.invalid("CLT package digest mismatch: \(pin.filename)")
      }
    }
    return (source, pins)
  }

  static func prepare(packages: URL, profile: RestoreProfile, journal: ExecutionJournal) throws
    -> Prepared
  {
    let product = profile.commandLineTools.product
    let (source, pins) = try validateInputs(
      packages: packages, profile: profile, cancellation: journal.cancellation)
    let staging = journal.output.appendingPathComponent("clt-packages")
    try SafeFile.makeDirectory(staging)
    var records: [Package] = []
    var combined: [String: PackageInventory.Entry] = [:]
    var expansions: [URL] = []
    for (index, pin) in pins.enumerated() {
      let package = try source.path(pin.filename)
      let signature = try journal.run(
        "clt-signature-\(index)",
        NativeCommand(.packages, arguments: ["--check-signature", package.path]))
      let text = String(decoding: try SafeFile.read(signature, limit: 1 << 20), as: UTF8.self)
      guard text.contains("Status: signed Apple Software") else {
        throw MisoError.invalid("CLT package is not signed Apple software")
      }
      let expanded = staging.appendingPathComponent(pin.filename + ".expanded")
      try journal.run(
        "clt-expand-\(index)",
        NativeCommand(
          .packages, arguments: ["--expand-full", package.path, expanded.path], timeout: 1800))
      let tree = try GuestVolume(expanded)
      try PackageInventory.validateInfo(
        SafeFile.read(tree.path("PackageInfo"), limit: 1 << 20), package: pin)
      let bom = try journal.run(
        "clt-bom-\(index)", NativeCommand(.bom, arguments: ["-p", "fmugsl", tree.path("Bom").path]))
      let listing = try SafeFile.read(bom, limit: 128 << 20)
      guard let inventory = String(data: listing, encoding: .utf8) else {
        throw MisoError.invalid("Invalid package BOM encoding")
      }
      var entries = try PackageInventory.parse(inventory)
      let payload = try tree.path("Payload")
      let payloadTree = try GuestVolume(payload)
      for (relative, control) in CLTPins.sizes[product + "/" + pin.filename] ?? [:] {
        let file = try payloadTree.path(relative)
        let info = try FileMetadata.inspect(file)
        guard var entry = entries[relative], entry.kind == S_IFREG, entry.size == control.bomBytes,
          info.st_mode & S_IFMT == S_IFREG, info.st_size == control.payloadBytes,
          try SafeFile.sha256(file) == control.sha256
        else { throw MisoError.invalid("CLT payload size control mismatch") }
        entry.size = control.payloadBytes
        entries[relative] = entry
      }
      try PackageInventory.inspect(payload, entries: &entries, cancellation: journal.cancellation)
      for (relative, entry) in entries {
        combined[relative] =
          try combined[relative].map {
            try PackageInventory.merge($0, entry, relative: relative, profile: profile)
          } ?? entry
      }
      var scripts: [String: String] = [:]
      if try tree.contains("Scripts") {
        let root = try tree.path("Scripts")
        try FileMetadata.walk(root) { relative, info in
          guard [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT) else {
            throw MisoError.invalid("Unexpected package script entry")
          }
          if info.st_mode & S_IFMT == S_IFREG {
            scripts[relative] = try SafeFile.sha256(root.appendingPathComponent(relative))
          }
        }
      }
      records.append(
        Package(
          filename: pin.filename, identifier: pin.identifier, version: pin.version,
          sha256: pin.sha256, scriptsNotExecuted: scripts))
      expansions.append(expanded)
    }
    guard Set(records.map(\.identifier)).count == records.count else {
      throw MisoError.invalid("Duplicate package identifier")
    }
    try SafeFile.writeNew(
      JSON.encode(combined), to: journal.output.appendingPathComponent("clt-inventory.json"))
    return Prepared(packages: records, entries: combined, expansions: expansions)
  }

  static func install(
    data: GuestVolume, packages: URL, profile: RestoreProfile, journal: ExecutionJournal
  ) throws -> Receipt {
    let product = profile.commandLineTools.product
    guard try !data.contains(PackageInventory.root) else {
      throw MisoError.invalid("CLT is already installed")
    }
    let receipts = "Library/Apple/System/Library/Receipts/"
    if try data.contains(receipts.dropLast().description) {
      guard
        try !FileManager.default.contentsOfDirectory(
          atPath: data.path(String(receipts.dropLast())).path
        ).contains(where: {
          $0.hasPrefix("com.apple.pkg.CLTools_") && $0.hasSuffix(".plist")
        })
      else { throw MisoError.invalid("Existing CLT receipts cannot be replaced") }
    }
    let prepared = try prepare(packages: packages, profile: profile, journal: journal)
    let records = prepared.packages
    let combined = prepared.entries
    let expansions = prepared.expansions
    var required: UInt64 = 8 << 30
    for (relative, entry) in combined {
      if entry.kind == S_IFREG {
        let (sum, overflow) = required.addingReportingOverflow(entry.size ?? 0)
        guard !overflow else { throw MisoError.invalid("Package size overflow") }
        required = sum
      }
      if !PackageInventory.ancestors.contains(relative), try data.contains(relative) {
        throw MisoError.invalid("CLT payload would overwrite an existing path: \(relative)")
      }
    }
    try Artifacts.requireSpace(required, at: data.root)
    for (index, expanded) in expansions.enumerated() {
      let payload = try GuestVolume(expanded.appendingPathComponent("Payload"))
      for (suffix, relative) in [
        ("tools", PackageInventory.root), ("marker", PackageInventory.temporaryMarker),
      ] {
        if try !payload.contains(relative) { continue }
        try journal.run(
          "clt-copy-\(index)-" + suffix,
          NativeCommand(
            .copy,
            arguments: [
              "--rsrc", "--extattr", "--acl", "--hfsCompression", payload.path(relative).path,
              data.path(relative, createParents: true).path,
            ], timeout: 1800))
      }
    }
    var files = 0
    var compressed = 0
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    for (relative, entry) in combined.sorted(by: { $0.key < $1.key })
    where !PackageInventory.ancestors.contains(relative) {
      try journal.cancellation.check()
      let path = try data.path(relative, allowLeafLink: true)
      guard lchown(path.path, entry.uid, entry.gid) == 0,
        lchmod(path.path, entry.mode & 0o7777) == 0
      else {
        throw MisoError.system("Restore CLT payload metadata", errno)
      }
      let info = try FileMetadata.inspect(path)
      guard info.st_mode == entry.mode, info.st_uid == entry.uid, info.st_gid == entry.gid else {
        throw MisoError.invalid("Installed CLT metadata differs from BOM")
      }
      if entry.kind == S_IFREG {
        guard let expectedSize = entry.size, info.st_size >= 0,
          UInt64(info.st_size) == expectedSize, try SafeFile.sha256(path) == entry.sha256
        else {
          throw MisoError.invalid("Installed CLT file differs from package")
        }
        files += 1
        logical += UInt64(info.st_size)
        allocated += UInt64(info.st_blocks) * 512
        if info.st_flags & UInt32(UF_COMPRESSED) != 0 { compressed += 1 }
      } else if entry.kind == S_IFLNK {
        guard try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == entry.link
        else {
          throw MisoError.invalid("Installed CLT link differs from package")
        }
      }
    }
    try AppleCode.validate(data.path(PackageInventory.root + "/usr/bin/clang"))
    let sdk = try data.path(PackageInventory.root + "/SDKs/MacOSX.sdk", allowLeafLink: true)
    guard
      try FileManager.default.destinationOfSymbolicLink(atPath: sdk.path)
        == profile.commandLineTools.sdk
    else {
      throw MisoError.invalid("Default CLT SDK differs from profile")
    }
    _ = try data.plist(
      PackageInventory.root + "/SDKs/" + profile.commandLineTools.sdk + "/SDKSettings.plist")
    let man = PackageInventory.root + "/usr/share/man"
    let index = try data.path(man + "/whatis")
    try journal.run(
      "clt-manual-index",
      NativeCommand(.manualIndex, arguments: ["-o", index.path, data.path(man).path], timeout: 600))
    guard chown(index.path, 0, 0) == 0, chmod(index.path, 0o644) == 0 else {
      throw MisoError.system("Set manual index metadata", errno)
    }
    struct Installed: Decodable {
      let version: String
      enum CodingKeys: String, CodingKey { case version = "pkg-version" }
    }
    for (index, record) in records.enumerated() {
      let receipt: [String: Any] = [
        "PackageIdentifier": record.identifier, "PackageVersion": record.version,
        "PackageFileName": record.filename, "InstallPrefixPath": "/", "InstallDate": Date(),
        "InstallProcessName": "miso",
      ]
      try data.mergePlist(receipts + record.identifier + ".plist", values: receipt)
      try data.write(
        receipts + record.identifier + ".bom",
        data: SafeFile.read(expansions[index].appendingPathComponent("Bom"), limit: 128 << 20))
      let installed = try journal.plist(
        Installed.self, name: "clt-receipt-\(index)",
        command: NativeCommand(
          .packages,
          arguments: [
            "--volume", data.root.path, "--pkg-info-plist", record.identifier,
          ]))
      guard installed.version == record.version else {
        throw MisoError.invalid("Installed CLT receipt lookup failed")
      }
    }
    try requireGuestAccess(data)
    return Receipt(
      product: product, packages: records, entries: combined.count, regularFiles: files,
      compressedFiles: compressed,
      logicalBytes: logical, allocatedBytes: allocated, sdk: profile.commandLineTools.sdk,
      manualIndexSHA256: try SafeFile.sha256(index))
  }
}

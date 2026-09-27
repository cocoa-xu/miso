import Darwin
import Foundation

public enum XcodePackageInstallation {
  public struct Details: Encodable {
    public let configuration: XcodeConfiguration
    public let packages: [XcodePackages.Package]
    public let installedFiles: Int
    public let licenseID: String
    public let firstLaunchComplete = false
    public let xcodeImageComplete = false
  }

  public static func install(
    source: URL, preparedArchive: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    try BaseImageStage.run(
      source: source, output: output, operation: "xcode-packages", layer: .xcode,
      cancellation: cancellation
    ) { bundle, target, journal in
      let inputs = output.appendingPathComponent("packages")
      let prepared = try XcodePackages.prepare(
        preparedArchive: preparedArchive, output: inputs, cancellation: journal.cancellation)
      guard prepared.target == target else {
        throw MisoError.invalid("Xcode packages and image targets differ")
      }
      let policies = try XcodePackages.Policy.standard(prepared.configuration)
      let session = try DiskImageSession(
        image: bundle.appendingPathComponent("disk.img"), readOnly: false, journal: journal)
      var files = 0
      var licenseID = ""
      try session.withAttachment { attached in
        let main = try BaseImageStage.mainContainer(attached)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: attached, journal: journal,
          name: "xcode-package-data", readOnly: false)
        let app = try data.directory(prepared.configuration.applicationPath).url
        _ = try XcodeArchive.inspect(app, target: target, configuration: prepared.configuration)
        try AppleCode.validate(app)
        for (index, policy) in policies.enumerated() {
          let package = prepared.packages[index]
          let tree = inputs.appendingPathComponent(policy.filename + ".expanded")
          let payload = try GuestVolume(tree.appendingPathComponent("Payload"))
          let inventory = try Artifacts.resolve(
            package.inventory, under: inputs, cancellation: journal.cancellation)
          let entries = try JSON.read([String: PackageInventory.Entry].self, from: inventory)
          files += try copy(
            payload: payload, entries: entries, policy: policy, data: data,
            name: "package-\(index)", journal: journal)
          try writeReceipt(package, inputs: inputs, data: data, index: index, journal: journal)
          if policy.filename == "MobileDeviceDevelopment.pkg" {
            let scripts = try GuestVolume(tree).directory("Scripts").url
            let path = try SafeFile.read(scripts.appendingPathComponent("100-rvictl"), limit: 128)
            guard path == Data("/Library/Apple/usr/bin\n".utf8) else {
              throw MisoError.invalid("Unreviewed MobileDevice PATH configuration")
            }
            try data.write("private/etc/paths.d/100-rvictl", data: path)
          }
        }
        licenseID = try acceptLicense(app: app, configuration: prepared.configuration, data: data)
      }
      return Details(
        configuration: prepared.configuration, packages: prepared.packages,
        installedFiles: files, licenseID: licenseID)
    }
  }

  static func copy(
    payload: GuestVolume, entries: [String: PackageInventory.Entry], policy: XcodePackages.Policy,
    data: GuestVolume, name: String, journal: ExecutionJournal
  ) throws -> Int {
    var expected = entries
    try PackageInventory.inspect(
      payload.root, entries: &expected, cancellation: journal.cancellation)
    guard expected == entries else { throw MisoError.invalid("Prepared Xcode payload changed") }
    let writable = try entries.filter { relative, _ in
      policy.roots.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }.map { (try policy.destination($0.key), $0.value) }.sorted { $0.0 < $1.0 }
    let bytes = writable.reduce(UInt64(0)) { $0 + ($1.1.size ?? 0) }
    try Artifacts.requireSpace(bytes + (1 << 30), at: data.root)
    for (relative, entry) in writable {
      let destination = try data.path(relative, createParents: true, allowLeafLink: true)
      var info = stat()
      if lstat(destination.path, &info) == 0 {
        guard info.st_mode & S_IFMT == entry.kind else {
          throw MisoError.invalid("Xcode package conflicts with an existing path: \(relative)")
        }
        if entry.kind == S_IFLNK {
          guard
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
              == entry.link
          else {
            throw MisoError.invalid("Xcode package would replace an unrelated link")
          }
        }
      } else if errno != ENOENT {
        throw MisoError.system("Inspect Xcode package destination", errno)
      }
    }
    for (index, root) in policy.roots.sorted().enumerated() {
      try journal.run(
        name + "-copy-\(index)",
        NativeCommand(
          .copy,
          arguments: [
            "--rsrc", "--extattr", "--acl", "--hfsCompression",
            payload.directory(root).url.path,
            data.path(policy.destination(root), createParents: true).path,
          ], timeout: 900))
    }
    var files = 0
    for (relative, entry) in writable {
      try journal.cancellation.check()
      let path = try data.path(relative, allowLeafLink: true)
      guard lchown(path.path, entry.uid, entry.gid) == 0,
        lchmod(path.path, entry.mode & 0o7777) == 0
      else {
        throw MisoError.system("Set Xcode package metadata", errno)
      }
      let info = try FileMetadata.inspect(path)
      guard info.st_mode == entry.mode, info.st_uid == entry.uid, info.st_gid == entry.gid else {
        throw MisoError.invalid("Installed Xcode package metadata differs")
      }
      if entry.kind == S_IFREG {
        guard info.st_size >= 0, UInt64(info.st_size) == entry.size,
          try SafeFile.sha256(path) == entry.sha256
        else {
          throw MisoError.invalid("Installed Xcode package file differs: \(relative)")
        }
        files += 1
      } else if entry.kind == S_IFLNK {
        guard try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == entry.link
        else {
          throw MisoError.invalid("Installed Xcode package link differs")
        }
      }
    }
    return files
  }

  static func writeReceipt(
    _ package: XcodePackages.Package, inputs: URL, data: GuestVolume, index: Int,
    journal: ExecutionJournal
  ) throws {
    let receipts = "Library/Apple/System/Library/Receipts/"
    let name = receipts + package.identifier
    guard try !data.contains(name + ".plist"), try !data.contains(name + ".bom") else {
      throw MisoError.invalid("Xcode package receipt is already installed")
    }
    try data.mergePlist(
      name + ".plist",
      values: [
        "PackageIdentifier": package.identifier, "PackageVersion": package.version,
        "PackageFileName": package.filename,
        "InstallPrefixPath": package.prefix.isEmpty ? "/" : "/" + package.prefix,
        "InstallDate": Date(), "InstallProcessName": "miso",
      ])
    let bom = try Artifacts.resolve(package.bom, under: inputs, cancellation: journal.cancellation)
    try data.write(name + ".bom", data: SafeFile.read(bom, limit: 32 << 20))
    struct Installed: Decodable {
      let version: String
      let prefix: String
      enum CodingKeys: String, CodingKey {
        case version = "pkg-version"
        case prefix = "install-location"
      }
    }
    let installed = try journal.plist(
      Installed.self, name: "package-receipt-\(index)",
      command: NativeCommand(
        .packages, arguments: ["--volume", data.root.path, "--pkg-info-plist", package.identifier]))
    guard installed.version == package.version,
      installed.prefix == (package.prefix.isEmpty ? "/" : "/" + package.prefix)
    else { throw MisoError.invalid("Installed Xcode package receipt lookup differs") }
  }

  static func acceptLicense(app: URL, configuration: XcodeConfiguration, data: GuestVolume) throws
    -> String
  {
    let license = try GuestVolume(app).plist("Contents/Resources/LicenseInfo.plist")
    guard license["licenseType"] as? String == "GM", license["licenseID"] as? String == "EA2002"
    else {
      throw MisoError.invalid("Unreviewed Xcode license identity")
    }
    try data.mergePlist(
      "Library/Preferences/com.apple.dt.Xcode.plist",
      values: [
        "IDELastGMLicenseAgreedTo": "EA2002",
        "IDEXcodeVersionForAgreedToGMLicense": configuration.version,
      ])
    return "EA2002"
  }
}

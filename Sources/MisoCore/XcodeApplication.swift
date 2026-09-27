import Darwin
import Foundation

public enum XcodeApplication {
  public struct Details: Encodable {
    public let configuration: XcodeConfiguration
    public let application: XcodeArchive.Application
    public let preparation: ImageBundle.FileRecord
    public let inventory: ImageBundle.FileRecord
    public let entries: Int
    public let developerDirectory: String
    public let xcodeImageComplete = false
    public let firstLaunchComplete = false
  }

  public static func install(
    source: URL, prepared: URL, output: URL, cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let input = try GuestVolume(prepared)
    let preparation = try Artifacts.record(input.path("archive.json"), relativeTo: prepared)
    let receipt = try JSON.read(XcodeArchive.Receipt.self, from: input.path("archive.json"))
    try receipt.configuration.validate()
    guard receipt.schemaVersion == 1, receipt.payload == "expanded/Xcode.app",
      !receipt.vmStarted, !receipt.runtimeVerified, !receipt.xcodeImageComplete
    else { throw MisoError.invalid("Unexpected prepared Xcode archive") }
    let app = try input.directory(receipt.payload).url
    return try BaseImageStage.run(
      source: source, output: output, operation: "xcode-application", layer: .xcode,
      cancellation: cancellation
    ) { bundle, target, journal in
      guard target == receipt.target else {
        throw MisoError.invalid("Prepared Xcode target differs from image")
      }
      try AppleCode.validate(app)
      try journal.run(
        "verify-source-xcode",
        NativeCommand(
          .codesign, arguments: ["--verify", "--deep", "--strict", app.path], timeout: 900))
      let application = try XcodeArchive.inspect(
        app, target: target, configuration: receipt.configuration)
      guard application == receipt.application else {
        throw MisoError.invalid("Prepared Xcode application changed")
      }
      let entries = try BaseInputArchive.inventory(app, cancellation: journal.cancellation)
      let inventoryURL = output.appendingPathComponent("application-inventory.json")
      try SafeFile.writeNew(JSON.encode(entries), to: inventoryURL)
      let inventory = try Artifacts.record(inventoryURL, relativeTo: output)
      let path = receipt.configuration.applicationPath
      let developerDirectory = "/" + path + "/Contents/Developer"
      let session = try DiskImageSession(
        image: bundle.appendingPathComponent("disk.img"), readOnly: false, journal: journal)
      try session.withAttachment { attached in
        let main = try BaseImageStage.mainContainer(attached)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: attached, journal: journal,
          name: "xcode-data", readOnly: false)
        guard try !data.contains(path) else {
          throw MisoError.invalid("Xcode application is already installed")
        }
        let destination = try data.path(path, createParents: true)
        let bytes = entries.reduce(UInt64(0)) { $0 + ($1.bytes ?? 0) }
        try Artifacts.requireSpace(bytes + (2 << 30), at: data.root)
        try journal.run(
          "copy-xcode",
          NativeCommand(
            .copy,
            arguments: [
              "--rsrc", "--extattr", "--acl", "--hfsCompression", app.path, destination.path,
            ],
            timeout: 1800))
        let installed = try GuestVolume(destination)
        for entry in entries {
          try journal.cancellation.check()
          let url =
            entry.path == "." ? destination : try installed.path(entry.path, allowLeafLink: true)
          guard lchown(url.path, 0, 80) == 0 else {
            throw MisoError.system("Set Xcode application ownership", errno)
          }
        }
        guard
          try BaseInputArchive.inventory(destination, cancellation: journal.cancellation) == entries
        else { throw MisoError.invalid("Installed Xcode differs from its authenticated input") }
        try BaseFileTree.requireOwnership(destination, entries: entries, uid: 0, gid: 80)
        try AppleCode.validate(destination)
        try journal.run(
          "verify-installed-xcode",
          NativeCommand(
            .codesign, arguments: ["--verify", "--deep", "--strict", destination.path], timeout: 900
          ))
        try select(developerDirectory, data: data)
      }
      guard try BaseInputArchive.inventory(app, cancellation: journal.cancellation) == entries,
        try Artifacts.record(input.path("archive.json"), relativeTo: prepared) == preparation
      else { throw MisoError.invalid("Xcode inputs changed during installation") }
      return Details(
        configuration: receipt.configuration, application: application, preparation: preparation,
        inventory: inventory, entries: entries.count, developerDirectory: developerDirectory)
    }
  }

  static func select(_ developerDirectory: String, data: GuestVolume) throws {
    let directory = try SafeFile.relativePath(String(developerDirectory.dropFirst()))
    guard developerDirectory.hasPrefix("/Applications/"),
      developerDirectory.hasSuffix(".app/Contents/Developer")
    else { throw MisoError.invalid("Invalid Xcode developer directory") }
    _ = try data.directory(directory)
    let selection = try data.path(
      "private/var/db/xcode_select_link", createParents: true, allowLeafLink: true)
    var info = stat()
    if lstat(selection.path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFLNK,
        try FileManager.default.destinationOfSymbolicLink(atPath: selection.path)
          == "/Library/Developer/CommandLineTools", unlink(selection.path) == 0
      else { throw MisoError.invalid("Unexpected existing developer selection") }
    } else if errno != ENOENT {
      throw MisoError.system("Inspect developer selection", errno)
    }
    guard symlink(developerDirectory, selection.path) == 0, lchown(selection.path, 0, 0) == 0 else {
      throw MisoError.system("Select guest Xcode", errno)
    }
  }
}

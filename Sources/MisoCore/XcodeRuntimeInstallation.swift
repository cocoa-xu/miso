import Darwin
import Foundation

public enum XcodeRuntimeInstallation {
  public struct Details: Encodable {
    public let requirement: XcodeRuntime.Requirement
    public let runtimeIdentifier: String
    public let runtimePath: String
    public let entries: Int
    public let logicalBytes: UInt64
    public let contentSHA256: String
    public let xcodeImageComplete = false
  }

  public struct Receipt: Encodable {
    public let input: XcodeRuntime.Receipt
    public let image: BaseStageReceipt<Details>
    public let temporaryInputsRemoved: Bool
    public let vmStarted = false
  }

  public static func install(
    source: URL, prepared: URL, configuration: XcodeConfiguration = .init(), output: URL,
    cancellation: CancellationToken? = nil
  ) async throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Offline runtime installation requires administrator privileges")
    }
    try configuration.validate()
    let original = try GuestVolume(prepared)
    let requested = try JSON.read(
      XcodeRuntime.Receipt.self, from: original.path("runtime.json"))
    try requested.requirement.validate(configuration)
    let journal = try ExecutionJournal(
      output: output, operation: "install-xcode-runtime", cancellation: cancellation)
    do {
      let inputs = output.appendingPathComponent("inputs")
      let authenticated = try await XcodeRuntime.prepare(
        requirement: requested.requirement, configuration: configuration,
        catalog: original.path("catalog.jwt"), archive: original.path("asset.aar"),
        output: inputs, cancellation: journal.cancellation)
      let image = try BaseImageStage.run(
        source: source, output: output.appendingPathComponent("image"),
        operation: "xcode-runtime-" + requested.requirement.platform.rawValue.lowercased(),
        layer: .xcode, cancellation: journal.cancellation
      ) { bundle, target, stage in
        let session = try DiskImageSession(
          image: bundle.appendingPathComponent("disk.img"), readOnly: false, journal: stage)
        return try session.withAttachment { attached in
          let main = try BaseImageStage.mainContainer(attached)
          let data = try ImageMounts.mount(
            main.volume(role: "Data"), session: attached, journal: stage,
            name: "runtime-data", readOnly: false)
          let app = try data.directory(configuration.applicationPath).url
          _ = try XcodeArchive.inspect(app, target: target, configuration: configuration)
          try AppleCode.validate(app)
          return try copy(authenticated, inputs: inputs, data: data, journal: stage)
        }
      }
      let disk = try GuestVolume(inputs).path(authenticated.diskImage)
      try DiskImageSession(image: disk, readOnly: true, journal: journal).requireDetached()
      for file in [disk, inputs.appendingPathComponent("asset.aar")] {
        guard try FileMetadata.inspect(file).st_mode & S_IFMT == S_IFREG else {
          throw MisoError.invalid("Unexpected temporary runtime input")
        }
        try FileManager.default.removeItem(at: file)
      }
      let result = Receipt(input: authenticated, image: image, temporaryInputsRemoved: true)
      try journal.finish(result)
      return result
    } catch {
      try journal.fail(error)
      throw error
    }
  }

  static func copy(
    _ input: XcodeRuntime.Receipt, inputs: URL, data: GuestVolume, journal: ExecutionJournal
  ) throws -> Details {
    let disk = try GuestVolume(inputs).path(input.diskImage)
    let session = try DiskImageSession(image: disk, readOnly: true, journal: journal)
    let mount = journal.output.appendingPathComponent("runtime-input")
    return try session.withAttachment(requireGPT: false, mountPoint: mount) { _ in
      let volume = try GuestVolume(mount)
      let identity = try XcodeRuntime.inspectRuntime(volume, requirement: input.requirement)
      guard identity.0 == input.runtimePath, identity.1 == input.runtimeIdentifier else {
        throw MisoError.invalid("Authenticated runtime identity changed")
      }
      let source = try volume.directory(identity.0).url
      let audit = try XcodeComponentPayload.copy(
        source, to: data, path: identity.0, journal: journal)
      let installed = try XcodeRuntime.inspectRuntimeBundle(
        GuestVolume(data.directory(identity.0).url), requirement: input.requirement)
      guard installed == identity.1 else {
        throw MisoError.invalid("Installed runtime identity differs")
      }
      return Details(
        requirement: input.requirement, runtimeIdentifier: identity.1, runtimePath: identity.0,
        entries: audit.entries, logicalBytes: audit.logicalBytes, contentSHA256: audit.contentSHA256
      )
    }
  }
}

enum XcodeComponentPayload {
  static func copy(_ source: URL, to data: GuestVolume, path: String, journal: ExecutionJournal)
    throws -> DataTemplate.Receipt
  {
    guard try !data.contains(path) else {
      throw MisoError.invalid("Xcode component destination already exists")
    }
    var bytes: UInt64 = 0
    var count = 0
    try FileMetadata.walk(source) { _, info in
      try journal.cancellation.check()
      guard [S_IFREG, S_IFDIR, S_IFLNK].contains(info.st_mode & S_IFMT) else {
        throw MisoError.invalid("Unsupported Xcode component entry")
      }
      count += 1
      if info.st_mode & S_IFMT == S_IFREG {
        guard info.st_size >= 0, UInt64(info.st_size) <= (64 << 30) - bytes else {
          throw MisoError.invalid("Xcode component exceeds its payload limit")
        }
        bytes += UInt64(info.st_size)
      }
    }
    try journal.setMetadata("componentPayloadEntries", value: count)
    try journal.setMetadata("componentPayloadBytes", value: bytes)
    try Artifacts.requireSpace(bytes + (1 << 30), at: data.root)
    let destination = try data.path(path, createParents: true)
    try journal.run(
      "copy-component",
      NativeCommand(
        .copy,
        arguments: [
          "--rsrc", "--extattr", "--acl", "--hfsCompression", source.path, destination.path,
        ],
        timeout: 3600))
    let copied = try GuestVolume(destination)
    var observed = 0
    try FileMetadata.walk(destination) { _, _ in
      try journal.cancellation.check()
      observed += 1
    }
    guard observed == count else { throw MisoError.invalid("Copied component entry count differs") }
    return try DataTemplate.audit(
      source: source, destination: copied, cancellation: journal.cancellation)
  }
}

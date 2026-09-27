import Darwin
import Foundation

public enum BaseInputArchive {
  public struct Specification: Codable, Sendable {
    public let schemaVersion: Int
    public let target: MacOSRelease
    public let resources: [Resource]
  }

  public struct Resource: Codable, Sendable {
    public let name: String
    public let path: String
    public let origin: String?
  }

  public struct Entry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let mode: UInt16
    public let bytes: UInt64?
    public let sha256: String?
    public let link: String?
  }

  public struct Snapshot: Codable, Sendable {
    public let name: String
    public let origin: String?
    public let entries: [Entry]
  }

  public struct Manifest: Codable, Sendable {
    public let schemaVersion: Int
    public let target: MacOSRelease
    public let host: HostInfo
    public let createdAt: Date
    public let resources: [Snapshot]
    public let completeBaseInputs: Bool
  }

  public struct Receipt: Codable, Sendable {
    public let target: MacOSRelease
    public let resources: Int
    public let entries: Int
    public let archiveSHA256: String
    public let completeBaseInputs: Bool
    public let vmStarted: Bool
  }

  static func inventory(
    _ source: URL, guestPath: String? = nil, cancellation: CancellationToken? = nil
  ) throws -> [Entry] {
    if let guestPath { _ = try SafeFile.relativePath(guestPath) }
    try SafeFile.requireNoSymlinks(source)
    let root = try FileMetadata.inspect(source)
    var entries: [Entry] = []
    func visit(_ url: URL, relative: String) throws {
      try cancellation?.check()
      let info = try FileMetadata.inspect(url)
      guard entries.count < 200_000, info.st_dev == root.st_dev, info.st_mode & 0o7000 == 0 else {
        throw MisoError.invalid("Unsafe or excessive input resource")
      }
      let mode = info.st_mode & 0o777
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        entries.append(
          Entry(path: relative, kind: "directory", mode: mode, bytes: nil, sha256: nil, link: nil))
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
          _ = try SafeFile.relativePath(name)
          try visit(
            url.appendingPathComponent(name),
            relative: relative == "." ? name : relative + "/" + name)
        }
      case S_IFREG:
        let input = try SafeFile.openRegular(url)
        defer { try? input.close() }
        entries.append(
          Entry(
            path: relative, kind: "file", mode: mode,
            bytes: try SafeFile.size(input),
            sha256: try SafeFile.sha256(input, cancellation: cancellation), link: nil))
      case S_IFLNK:
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        do {
          if let guestPath {
            if link.hasPrefix("/") {
              _ = try SafeFile.relativePath(String(link.dropFirst()))
            } else {
              _ = try SafeFile.relativeLink(link, at: guestPath + "/" + relative)
            }
          } else {
            _ = try SafeFile.relativeLink(link, at: relative)
            guard
              url.resolvingSymlinksInPath().path.hasPrefix(
                source.resolvingSymlinksInPath().path + "/")
            else {
              throw MisoError.invalid("Input symlink escapes resource")
            }
          }
        } catch {
          throw MisoError.invalid("Invalid symbolic link: \(relative) -> \(link)")
        }
        entries.append(
          Entry(path: relative, kind: "symlink", mode: mode, bytes: nil, sha256: nil, link: link))
      default: throw MisoError.invalid("Unsupported input resource file type")
      }
    }
    try visit(source, relative: ".")
    return entries.sorted { $0.path < $1.path }
  }

  public static func create(specification: URL, output: URL, cancellation: CancellationToken? = nil)
    throws -> Receipt
  {
    let spec = try JSON.read(Specification.self, from: specification)
    try validate(schema: spec.schemaVersion, names: spec.resources.map(\.name))
    _ = try MacOSVersion(spec.target.version)
    let sources = try spec.resources.map { resource -> URL in
      let url =
        resource.path.hasPrefix("/")
        ? URL(fileURLWithPath: resource.path)
        : specification.deletingLastPathComponent().appendingPathComponent(resource.path)
      let source = url.standardized
      try SafeFile.requireNoSymlinks(source)
      guard output.standardized.path != source.path,
        !output.standardized.path.hasPrefix(source.path + "/")
      else { throw MisoError.invalid("Invalid archive resource path") }
      return source
    }
    let journal = try ExecutionJournal(
      output: output, operation: "archive-base-inputs", cancellation: cancellation)
    return try journal.perform {
      let root = journal.output.appendingPathComponent("resources")
      try SafeFile.makeDirectory(root)
      var snapshots: [Snapshot] = []
      for (resource, source) in zip(spec.resources, sources) {
        let before = try inventory(source, cancellation: journal.cancellation)
        let destination = root.appendingPathComponent(resource.name)
        for entry in before.filter({ $0.kind == "directory" }).sorted(by: {
          $0.path.count < $1.path.count
        }) {
          let path =
            entry.path == "." ? destination : destination.appendingPathComponent(entry.path)
          try SafeFile.makeDirectory(path)
        }
        for entry in before where entry.kind == "file" {
          let origin = entry.path == "." ? source : source.appendingPathComponent(entry.path)
          let path =
            entry.path == "." ? destination : destination.appendingPathComponent(entry.path)
          if entry.bytes == 0 {
            try SafeFile.writeNew(Data(), to: path)
          } else {
            try Artifacts.copy(
              origin, to: path, maximumBytes: entry.bytes!, cancellation: journal.cancellation)
          }
          guard chmod(path.path, entry.mode) == 0 else {
            throw MisoError.system("Preserve archive file mode", errno)
          }
        }
        for entry in before where entry.kind == "symlink" {
          let path = destination.appendingPathComponent(entry.path)
          guard let link = entry.link, symlink(link, path.path) == 0,
            lchmod(path.path, entry.mode) == 0
          else { throw MisoError.system("Preserve archive symlink", errno) }
        }
        for entry in before.filter({ $0.kind == "directory" }).sorted(by: {
          $0.path.count > $1.path.count
        }) {
          let path =
            entry.path == "." ? destination : destination.appendingPathComponent(entry.path)
          guard chmod(path.path, entry.mode) == 0 else {
            throw MisoError.system("Preserve archive directory mode", errno)
          }
        }
        guard try inventory(source, cancellation: journal.cancellation) == before,
          try inventory(destination, cancellation: journal.cancellation) == before
        else { throw MisoError.invalid("Input resource changed during archival") }
        snapshots.append(Snapshot(name: resource.name, origin: resource.origin, entries: before))
      }
      let manifest = Manifest(
        schemaVersion: 1, target: spec.target, host: journal.record.host,
        createdAt: Date(), resources: snapshots, completeBaseInputs: false)
      try SafeFile.writeNew(
        JSON.encode(manifest), to: journal.output.appendingPathComponent("archive.json"))
      return try verify(journal.output, cancellation: journal.cancellation)
    }
  }

  public static func verify(_ directory: URL, cancellation: CancellationToken? = nil) throws
    -> Receipt
  {
    _ = try GuestVolume(directory)
    let manifestURL = directory.appendingPathComponent("archive.json")
    let bytes = try SafeFile.read(manifestURL, limit: 64 << 20)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(Manifest.self, from: bytes)
    try validate(schema: manifest.schemaVersion, names: manifest.resources.map(\.name))
    _ = try MacOSVersion(manifest.target.version)
    let root = directory.appendingPathComponent("resources")
    _ = try GuestVolume(root)
    guard
      Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        == Set(manifest.resources.map(\.name))
    else {
      throw MisoError.invalid("Archive resource set changed")
    }
    for resource in manifest.resources {
      guard
        try inventory(root.appendingPathComponent(resource.name), cancellation: cancellation)
          == resource.entries
      else {
        throw MisoError.invalid("Archived resource changed: \(resource.name)")
      }
    }
    return Receipt(
      target: manifest.target, resources: manifest.resources.count,
      entries: manifest.resources.reduce(0) { $0 + $1.entries.count },
      archiveSHA256: SafeFile.sha256(bytes), completeBaseInputs: manifest.completeBaseInputs,
      vmStarted: false)
  }

  private static func validate(schema: Int, names: [String]) throws {
    guard schema == 1, !names.isEmpty, names.count <= 256, Set(names).count == names.count,
      names.allSatisfy({
        $0.range(of: #"\A[a-z0-9][a-z0-9-]{0,79}\z"#, options: .regularExpression) != nil
      })
    else { throw MisoError.invalid("Invalid Base archive specification") }
  }
}

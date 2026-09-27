import Darwin
import Foundation

struct PackageInventory {
  static let root = "Library/Developer/CommandLineTools"
  static let ancestors: Set<String> = ["Library", "Library/Developer", "private", "private/tmp"]
  static let temporaryMarker =
    "private/tmp/.BBE72B41371180178E084EEAF106AED4F350939DB95D3516864A1CC62E7AE82F"

  struct Entry: Codable, Equatable, Sendable {
    let mode: mode_t
    let uid: uid_t
    var gid: gid_t
    var size: UInt64?
    let link: String
    var sha256: String?
    var kind: mode_t { mode & S_IFMT }
  }

  static func parse(_ text: String) throws -> [String: Entry] {
    try parse(text, roots: [root, temporaryMarker], linkRoot: "Library/Developer")
  }

  static func parse(_ text: String, roots: Set<String>, linkRoot: String) throws -> [String: Entry]
  {
    guard !roots.isEmpty else { throw MisoError.invalid("Missing package payload roots") }
    _ = try SafeFile.relativePath(linkRoot)
    var ancestors = Set<String>()
    for root in roots {
      _ = try SafeFile.relativePath(root)
      var parent = (root as NSString).deletingLastPathComponent
      while !parent.isEmpty {
        ancestors.insert(parent)
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    var entries: [String: Entry] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 6, fields[0] == "." || fields[0].hasPrefix("./") else {
        throw MisoError.invalid("Unsupported package BOM record")
      }
      if fields[0] == "." { continue }
      let relative = try SafeFile.relativePath(String(fields[0].dropFirst(2)))
      guard
        ancestors.contains(relative)
          || roots.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }),
        let mode = mode_t(fields[1], radix: 8), let uid = uid_t(fields[2]),
        let gid = gid_t(fields[3]),
        [S_IFDIR, S_IFREG, S_IFLNK].contains(mode & S_IFMT), uid == 0, [0, 80].contains(gid),
        mode & 0o7000 == 0,
        entries[relative] == nil
      else { throw MisoError.invalid("Unexpected package payload location or metadata") }
      let size = fields[4].isEmpty ? nil : UInt64(fields[4])
      guard fields[4].isEmpty || size != nil, mode & S_IFMT != S_IFREG || size != nil else {
        throw MisoError.invalid("Invalid package payload size")
      }
      if mode & S_IFMT == S_IFLNK {
        let resolved = try SafeFile.relativeLink(fields[5], at: relative)
        guard resolved.hasPrefix(linkRoot + "/")
        else { throw MisoError.invalid("Unsafe package symbolic link") }
      } else if !fields[5].isEmpty {
        throw MisoError.invalid("Unexpected package link field")
      }
      entries[relative] = Entry(mode: mode, uid: uid, gid: gid, size: size, link: fields[5])
      guard entries.count <= 2_000_000 else {
        throw MisoError.invalid("Package entry count exceeds limit")
      }
    }
    for relative in entries.keys {
      var parent = (relative as NSString).deletingLastPathComponent
      while !parent.isEmpty {
        guard entries[parent]?.kind != S_IFLNK else {
          throw MisoError.invalid("Package path traverses a symbolic link")
        }
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    return entries
  }

  static func inspect(
    _ payload: URL, entries: inout [String: Entry], cancellation: CancellationToken
  ) throws {
    var observed = Set<String>()
    try FileMetadata.walk(payload) { relative, info in
      try cancellation.check()
      guard var entry = entries[relative], entry.kind == info.st_mode & S_IFMT else {
        throw MisoError.invalid("Payload entry differs from BOM: \(relative)")
      }
      let path = payload.appendingPathComponent(relative)
      if entry.kind == S_IFREG {
        guard entry.size == UInt64(info.st_size) else {
          throw MisoError.invalid("Package payload size differs from BOM: \(relative)")
        }
        entry.sha256 = try SafeFile.sha256(path)
        entries[relative] = entry
      } else if entry.kind == S_IFLNK {
        guard try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == entry.link
        else {
          throw MisoError.invalid("Package payload link differs from BOM")
        }
      }
      observed.insert(relative)
    }
    guard observed == Set(entries.keys) else {
      throw MisoError.invalid("Payload inventory is incomplete")
    }
  }

  static func merge(_ left: Entry, _ right: Entry, relative: String, profile: RestoreProfile) throws
    -> Entry
  {
    if left == right { return right }
    let allowed: Set<String> =
      profile.family == .tahoe
      ? ["Library/Developer", root, root + "/usr"]
      : profile.family == .goldenGate ? ["Library/Developer"] : []
    guard allowed.contains(relative),
      [left, right].allSatisfy({
        $0.mode == S_IFDIR | 0o755 && $0.uid == 0 && [0, 80].contains($0.gid)
          && $0.size == nil && $0.link.isEmpty && $0.sha256 == nil
      })
    else { throw MisoError.invalid("Conflicting package payloads: \(relative)") }
    var merged = right
    merged.gid = 80
    return merged
  }

  static func validateInfo(_ data: Data, package: CLTPins.Package) throws {
    final class Delegate: NSObject, XMLParserDelegate {
      var root: (String, [String: String])?
      func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
      ) {
        if root == nil { root = (name, attributes) }
      }
    }
    let delegate = Delegate()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    guard parser.parse(), let (name, attributes) = delegate.root, name == "pkg-info",
      attributes["identifier"] == package.identifier, attributes["version"] == package.version,
      attributes["useHFSPlusCompression"] == "true"
    else { throw MisoError.invalid("Package identifier, version or compression policy mismatch") }
  }
}

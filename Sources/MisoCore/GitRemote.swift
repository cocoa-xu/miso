import Foundation

struct GitRemote {
  struct Selection: Codable, Equatable {
    let reference: String
    let objectID: String
    let commitID: String
  }

  enum Packet: Equatable {
    case flush, delimiter, end
    case data(Data)
  }

  let references: [String: Selection]

  init(capabilities: Data, references data: Data) throws {
    try Self.validateCapabilities(capabilities)
    guard data.count <= 8 << 20 else { throw MisoError.invalid("Excessive Git advertisement") }
    var cursor = GitPack.Cursor(data: data)
    var references: [String: Selection] = [:]
    while let line = try Self.line(&cursor) {
      guard references.count < 50_000 else { throw MisoError.invalid("Excessive Git references") }
      let parts = line.trimmingCharacters(in: .newlines).split(separator: " ")
      guard (2...4).contains(parts.count) else {
        throw MisoError.invalid("Malformed Git reference")
      }
      let id = String(parts[0])
      _ = try Self.objectID(id)
      let name = String(parts[1])
      try Self.validateReference(name)
      var peeled: String?
      var symref: String?
      for attribute in parts.dropFirst(2) {
        if attribute.hasPrefix("peeled:"), peeled == nil {
          peeled = String(attribute.dropFirst(7))
          _ = try Self.objectID(peeled!)
        } else if attribute.hasPrefix("symref-target:"), symref == nil {
          symref = String(attribute.dropFirst(14))
          try Self.validateReference(symref!)
        } else {
          throw MisoError.invalid("Unexpected Git reference attribute")
        }
      }
      let selection = Selection(reference: name, objectID: id, commitID: peeled ?? id)
      guard references.updateValue(selection, forKey: name) == nil else {
        throw MisoError.invalid("Duplicate Git reference")
      }
    }
    guard cursor.offset == data.count, !references.isEmpty else {
      throw MisoError.invalid("Empty or trailing Git references")
    }
    self.references = references
  }

  static func validateCapabilities(_ data: Data) throws {
    guard data.count <= 65_536 else { throw MisoError.invalid("Excessive Git capabilities") }
    var cursor = GitPack.Cursor(data: data)
    var version = try line(&cursor)
    if version == "# service=git-upload-pack\n" {
      guard try line(&cursor) == nil else {
        throw MisoError.invalid("Invalid Git service envelope")
      }
      version = try line(&cursor)
    }
    guard version == "version 2\n" else {
      throw MisoError.unsupported("Expected Git protocol version 2")
    }
    var capabilities: [String: String] = [:]
    while let line = try line(&cursor) {
      let parts = line.trimmingCharacters(in: .newlines).split(
        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard !parts[0].isEmpty, capabilities.count < 128,
        capabilities.updateValue(parts.count == 2 ? String(parts[1]) : "", forKey: String(parts[0]))
          == nil
      else { throw MisoError.invalid("Invalid Git capabilities") }
    }
    guard cursor.offset == data.count, capabilities["ls-refs"] != nil,
      capabilities["fetch"]?.split(separator: " ").contains("shallow") == true,
      capabilities["object-format"] == nil || capabilities["object-format"] == "sha1"
    else { throw MisoError.unsupported("Expected shallow SHA-1 Git transport") }
  }

  func select(_ reference: String?) throws -> Selection {
    let name = reference ?? "HEAD"
    try Self.validateReference(name)
    guard let selected = references[name] else {
      throw MisoError.invalid("Git reference not advertised: \(name)")
    }
    return selected
  }

  static func referenceRequest(_ prefix: String) throws -> Data {
    try validateReference(prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix)
    return try packet("command=ls-refs\n") + Data("0001".utf8)
      + packet("peel\n") + packet("symrefs\n") + packet("ref-prefix \(prefix)\n")
      + Data("0000".utf8)
  }

  func request(_ selection: Selection) throws -> Data {
    guard try select(selection.reference) == selection else {
      throw MisoError.invalid("Git selection differs from advertisement")
    }
    return try Self.fetchRequest(selection)
  }

  static func fetchRequest(_ selection: Selection) throws -> Data {
    try validateReference(selection.reference)
    _ = try objectID(selection.objectID)
    _ = try objectID(selection.commitID)
    return try Self.packet("command=fetch\n") + Data("0001".utf8)
      + Self.packet("want \(selection.objectID)\n") + Self.packet("deepen 1\n")
      + Self.packet("no-progress\n") + Self.packet("ofs-delta\n") + Self.packet("done\n")
      + Data("0000".utf8)
  }

  static func response(_ data: Data, selection: Selection) throws -> Data {
    guard data.count <= (128 << 20) + 65_536 else {
      throw MisoError.invalid("Excessive Git response")
    }
    var cursor = GitPack.Cursor(data: data)
    var section = try line(&cursor)
    if section == "shallow-info\n" {
      var shallow = Set<String>()
      while true {
        let value = try read(&cursor)
        if value == .delimiter { break }
        guard case .data(let bytes) = value,
          String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .newlines)
            == "shallow \(selection.commitID)",
          shallow.insert(selection.commitID).inserted
        else { throw MisoError.invalid("Unexpected Git shallow boundary") }
      }
      section = try line(&cursor)
    }
    guard section == "packfile\n" else { throw MisoError.invalid("Expected Git packfile section") }
    var pack = Data()
    while true {
      let value = try read(&cursor)
      if value == .flush { break }
      guard case .data(let bytes) = value, let band = bytes.first else {
        throw MisoError.invalid("Invalid Git sideband packet")
      }
      switch band {
      case 1:
        guard pack.count + bytes.count - 1 <= 128 << 20 else {
          throw MisoError.invalid("Excessive Git pack")
        }
        pack.append(bytes.dropFirst())
      case 2: break
      default: throw MisoError.invalid("Git server returned an error or unknown sideband")
      }
    }
    if cursor.offset < data.count {
      guard try read(&cursor) == .end else { throw MisoError.invalid("Trailing Git response") }
    }
    guard cursor.offset == data.count, pack.starts(with: Data("PACK".utf8)) else {
      throw MisoError.invalid("Missing Git pack or trailing response data")
    }
    return pack
  }

  static func repositoryURL(_ repository: String) throws -> URL {
    guard
      repository.range(
        of: #"\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\z"#,
        options: .regularExpression) != nil,
      !repository.contains(".."), !repository.hasSuffix(".git"), !repository.hasSuffix(".")
    else { throw MisoError.invalid("Invalid GitHub repository") }
    return URL(string: "https://github.com/\(repository).git")!
  }

  static func objectID(_ value: String) throws -> Data {
    guard value.utf8.count == 40,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      value != String(repeating: "0", count: 40)
    else { throw MisoError.invalid("Invalid Git SHA-1 object ID") }
    let bytes = Array(value.utf8)
    func nibble(_ byte: UInt8) -> UInt8 { byte < 58 ? byte - 48 : byte - 87 }
    return Data(
      stride(from: 0, to: 40, by: 2).map { nibble(bytes[$0]) << 4 | nibble(bytes[$0 + 1]) })
  }

  static func validateReference(_ name: String) throws {
    guard name == "HEAD" || name.hasPrefix("refs/"), name.utf8.count <= 1024,
      name.utf8.allSatisfy({ (33...126).contains($0) && !Data("~^:?*[\\".utf8).contains($0) }),
      !name.contains(".."), !name.contains("@{"), !name.hasSuffix("."),
      name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
        !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
      })
    else { throw MisoError.invalid("Unsafe Git reference") }
  }

  static func packet(_ value: String) throws -> Data { try packet(Data(value.utf8)) }

  static func packet(_ data: Data) throws -> Data {
    guard data.count <= 65_516 else { throw MisoError.invalid("Oversized Git packet") }
    return Data(String(format: "%04x", data.count + 4).utf8) + data
  }

  static func read(_ cursor: inout GitPack.Cursor) throws -> Packet {
    let header = try cursor.take(4)
    guard header.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let size = Int(String(decoding: header, as: UTF8.self), radix: 16)
    else { throw MisoError.invalid("Invalid Git packet header") }
    switch size {
    case 0: return .flush
    case 1: return .delimiter
    case 2: return .end
    case 4...65_520: return .data(try cursor.take(size - 4))
    default: throw MisoError.invalid("Invalid Git packet size")
    }
  }

  static func line(_ cursor: inout GitPack.Cursor) throws -> String? {
    let value = try read(&cursor)
    if value == .flush { return nil }
    guard case .data(let bytes) = value, let line = String(data: bytes, encoding: .utf8),
      !line.isEmpty
    else {
      throw MisoError.invalid("Expected Git text packet")
    }
    return line
  }
}

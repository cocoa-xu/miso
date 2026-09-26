import Foundation

public enum TemplateUpgrade {
  public typealias Inventory = [String: [String: JSONValue]]

  public struct Action: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
      case add, replace, remove
      case alreadyCurrent = "already-current"
      case preserveDeletion = "preserve-deletion"
      case conflictAdd = "conflict-add"
      case conflictModified = "conflict-modified"
    }
    public let path: String
    public let action: Kind
    public let old: [String: JSONValue]?
    public let new: [String: JSONValue]?
    public let current: [String: JSONValue]?
    public var isConflict: Bool { action == .conflictAdd || action == .conflictModified }
  }

  public static func normalize(_ entry: [String: JSONValue]?) throws -> [String: JSONValue]? {
    guard var entry else { return nil }
    guard case .integer(let flags) = entry["flags"], flags >= 0, flags <= UInt32.max,
      case .object(var attributes) = entry["xattrs"]
    else {
      throw MisoError.invalid("Inventory metadata requires integer flags and an xattrs object")
    }
    for key in ["inode", "nlink", "mtime_ns", "birthtime"] { entry.removeValue(forKey: key) }
    if flags & 0x20 != 0 {
      attributes.removeValue(forKey: "com.apple.decmpfs")
      attributes.removeValue(forKey: "com.apple.ResourceFork")
    }
    entry["flags"] = .integer(flags & ~0x20)
    entry["xattrs"] = .object(attributes)
    return entry
  }

  public static func plan(old: Inventory, new: Inventory, current: Inventory) throws -> [Action] {
    for inventory in [old, new, current] {
      for (path, entry) in inventory {
        if path != "." { _ = try SafeFile.relativePath(path) }
        _ = try normalize(entry)
      }
    }
    return try Set(old.keys).union(new.keys).sorted().compactMap { path in
      let left = try normalize(old[path])
      let right = try normalize(new[path])
      let live = try normalize(current[path])
      guard path != ".", left != right else { return nil }
      let kind: Action.Kind
      if live == right {
        kind = .alreadyCurrent
      } else if left == nil {
        kind = live == nil ? .add : .conflictAdd
      } else if live == left {
        kind = right == nil ? .remove : .replace
      } else if live == nil {
        kind = .preserveDeletion
      } else {
        kind = .conflictModified
      }
      return Action(path: path, action: kind, old: left, new: right, current: live)
    }
  }

  public static func requireUnambiguous(_ actions: [Action]) throws {
    let conflicts = actions.filter(\.isConflict)
    guard conflicts.isEmpty else {
      throw MisoError.invalid(
        "Data template conflicts require an explicit policy: "
          + conflicts.prefix(10).map(\.path).joined(separator: ", "))
    }
  }
}

import Foundation

struct VersionRequirement {
  enum Syntax { case npm, gem }

  private struct Bound {
    let operation: String
    let version: StableVersion

    func contains(_ value: StableVersion) -> Bool {
      switch operation {
      case ">=": value >= version
      case ">": value > version
      case "<=": value <= version
      case "<": value < version
      case "!=": value != version
      default: value == version
      }
    }
  }

  private let alternatives: [[Bound]]

  init(_ expression: String, syntax: Syntax) throws {
    guard expression.utf8.count <= 2048 else {
      throw MisoError.invalid("Version requirement exceeds limit")
    }
    let branches = syntax == .npm ? expression.components(separatedBy: "||") : [expression]
    guard branches.count <= 32 else { throw MisoError.invalid("Too many version alternatives") }
    alternatives = try branches.map { branch in
      let normalized = branch.replacingOccurrences(
        of: #"(>=|<=|!=|~>|[><=~^])\s+"#, with: "$1", options: .regularExpression)
      let tokens = normalized.split(whereSeparator: {
        $0.isWhitespace || (syntax == .gem && $0 == ",")
      }).map(String.init)
      guard tokens.count <= 64 else { throw MisoError.invalid("Too many version constraints") }
      if syntax == .npm, tokens.count == 3, tokens[1] == "-" {
        let lower = try Self.parts(tokens[0], syntax: syntax)
        let upper = try Self.parts(tokens[2], syntax: syntax)
        guard !lower.isEmpty, !upper.isEmpty else {
          throw MisoError.invalid("Invalid version interval")
        }
        return [
          Bound(operation: ">=", version: try Self.version(lower)),
          Bound(
            operation: upper.count == 3 && !tokens[2].hasSuffix("-0") ? "<=" : "<",
            version: try upper.count == 3 ? Self.version(upper) : Self.next(upper, upper.count - 1)),
        ]
      }
      return try tokens.flatMap { try Self.bounds($0, syntax: syntax) }
    }
  }

  func contains(_ version: String) throws -> Bool {
    let value = try StableVersion(version)
    return alternatives.contains { $0.allSatisfy { $0.contains(value) } }
  }

  private static func parts(_ input: String, syntax: Syntax) throws -> [UInt32] {
    var text = input
    if syntax == .npm, text.hasPrefix("v") { text.removeFirst() }
    if syntax == .npm, text.hasSuffix("-0") { text.removeLast(2) }
    let fields = text.split(separator: ".", omittingEmptySubsequences: false)
    guard !fields.isEmpty, fields.count <= (syntax == .npm ? 3 : 4) else {
      throw MisoError.unsupported("Version requirement syntax: \(input)")
    }
    var result: [UInt32] = []
    var wildcard = false
    for field in fields {
      if syntax == .npm, ["*", "x", "X"].contains(field) {
        wildcard = true
        continue
      }
      guard !wildcard, field.range(of: #"\A(0|[1-9][0-9]*)\z"#, options: .regularExpression) != nil,
        let number = UInt32(field)
      else { throw MisoError.unsupported("Version requirement syntax: \(input)") }
      result.append(number)
    }
    return result
  }

  private static func version(_ parts: [UInt32]) throws -> StableVersion {
    try StableVersion((parts.isEmpty ? [0] : parts).map(String.init).joined(separator: "."))
  }

  private static func next(_ parts: [UInt32], _ position: Int) throws -> StableVersion {
    var result = Array(parts.prefix(position + 1))
    guard result.indices.contains(position), result[position] < UInt32.max else {
      throw MisoError.invalid("Version requirement boundary overflow")
    }
    result[position] += 1
    return try version(result)
  }

  private static func bounds(_ token: String, syntax: Syntax) throws -> [Bound] {
    let operations =
      syntax == .npm
      ? [">=", "<=", ">", "<", "=", "~", "^"]
      : ["~>", ">=", "<=", "!=", ">", "<", "="]
    var operation = operations.first(where: { token.hasPrefix($0) }) ?? ""
    let values = try parts(String(token.dropFirst(operation.count)), syntax: syntax)
    let lower = try version(values)
    func bound(_ operation: String, _ value: StableVersion) -> Bound {
      Bound(operation: operation, version: value)
    }
    if syntax == .gem {
      if operation == "~>" {
        return [bound(">=", lower), bound("<", try next(values, max(0, values.count - 2)))]
      }
      return [bound(operation, lower)]
    }
    if token.hasSuffix("-0") {
      if operation == ">" { operation = ">=" }
      if operation == "<=" { operation = "<" }
      if ["", "="].contains(operation) { return [bound("<", try version([0]))] }
    }
    if values.isEmpty { return ["<", ">"].contains(operation) ? [bound("<", lower)] : [] }
    switch operation {
    case "^":
      let position = values.firstIndex(where: { $0 != 0 }) ?? (values.count - 1)
      return [bound(">=", lower), bound("<", try next(values, position))]
    case "~":
      return [bound(">=", lower), bound("<", try next(values, min(1, values.count - 1)))]
    case ">", "<=":
      if values.count < 3 {
        return [bound(operation == ">" ? ">=" : "<", try next(values, values.count - 1))]
      }
      return [bound(operation, lower)]
    case ">=", "<": return [bound(operation, lower)]
    default:
      if values.count == 3 { return [bound("=", lower)] }
      return [bound(">=", lower), bound("<", try next(values, values.count - 1))]
    }
  }
}

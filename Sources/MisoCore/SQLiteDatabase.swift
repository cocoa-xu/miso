import CMiso
import Foundation

final class SQLiteDatabase {
  enum Value: Equatable, Codable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
  }

  private var handle: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(_ url: URL? = nil, readOnly: Bool = false) throws {
    let flags =
      (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
      | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_PRIVATECACHE
    guard sqlite3_open_v2(url?.path ?? ":memory:", &handle, flags, nil) == SQLITE_OK else {
      let error = failure(
        "Open database \(url?.path ?? ":memory:") (\(sqlite3_extended_errcode(handle)), errno \(sqlite3_system_errno(handle)))"
      )
      sqlite3_close(handle)
      handle = nil
      throw error
    }
    sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 16 << 20)
    sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 1 << 20)
    sqlite3_limit(handle, SQLITE_LIMIT_ATTACHED, 0)
    sqlite3_busy_timeout(handle, 1000)
    sqlite3_set_authorizer(
      handle,
      { _, action, _, _, _, _ in
        action == SQLITE_ATTACH || action == SQLITE_DETACH ? SQLITE_DENY : SQLITE_OK
      }, nil)
  }

  deinit { sqlite3_close(handle) }

  func script(_ sql: String) throws {
    guard !sql.contains("\0"), sql.utf8.count <= 1 << 20,
      sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    else { throw failure("Execute database schema") }
  }

  @discardableResult
  func rows(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
    guard !sql.contains("\0"), sql.utf8.count <= 1 << 20 else {
      throw MisoError.invalid("Invalid database statement")
    }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    try sql.withCString { pointer in
      var tail: UnsafePointer<CChar>?
      guard sqlite3_prepare_v2(handle, pointer, -1, &statement, &tail) == SQLITE_OK,
        let tail, String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        statement != nil
      else { throw failure("Prepare single database statement") }
    }
    guard sqlite3_bind_parameter_count(statement) == values.count else {
      throw MisoError.invalid("Database binding count mismatch")
    }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
      case .real(let number): result = sqlite3_bind_double(statement, index, number)
      case .text(let text):
        guard !text.contains("\0") else { throw MisoError.invalid("NUL database text") }
        result = sqlite3_bind_text(statement, index, text, -1, transient)
      case .blob(let data):
        result =
          data.isEmpty
          ? sqlite3_bind_zeroblob(statement, index, 0)
          : data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
          }
      case .null: result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else { throw failure("Bind database value") }
    }
    var result: [[Value]] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return result }
      guard status == SQLITE_ROW, result.count < 100_000 else {
        throw failure("Read bounded database result")
      }
      result.append(
        try (0..<sqlite3_column_count(statement)).map { column in
          switch sqlite3_column_type(statement, column) {
          case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
          case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
          case SQLITE_NULL: return .null
          case SQLITE_TEXT:
            guard let bytes = sqlite3_column_text(statement, column),
              let value = String(
                data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))),
                encoding: .utf8)
            else { throw MisoError.invalid("Invalid database text") }
            return .text(value)
          case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            if count == 0 { return .blob(Data()) }
            guard let bytes = sqlite3_column_blob(statement, column) else {
              throw MisoError.invalid("Missing database bytes")
            }
            return .blob(Data(bytes: bytes, count: count))
          default: throw MisoError.invalid("Unsupported database value")
          }
        })
    }
  }

  private func failure(_ operation: String) -> MisoError {
    .invalid(operation + ": " + String(cString: sqlite3_errmsg(handle)))
  }
}

import Darwin
import Foundation

enum BaseTCC {
  static func directoryMode(userOwned: Bool) -> mode_t {
    userOwned ? 0o700 : 0o755
  }

  static func verifyDirectory(_ url: URL, uid: uid_t, gid: gid_t, userOwned: Bool) throws {
    let info = try FileMetadata.inspect(url)
    guard info.st_uid == uid, info.st_gid == gid,
      info.st_mode == S_IFDIR | directoryMode(userOwned: userOwned)
    else { throw MisoError.invalid("TCC directory ownership or mode differs") }
  }

  struct Grant: Equatable {
    let service: String
    let client: String
    let receiver: String?
  }

  static func grants(agent: String) throws -> [Grant] {
    _ = try SafeFile.relativePath(agent)
    guard agent.hasPrefix("opt/homebrew/Cellar/tart-guest-agent/"),
      agent.hasSuffix("/bin/tart-guest-agent")
    else {
      throw MisoError.invalid("Unexpected guest agent path")
    }
    var result: [Grant] = []
    for client in ["/usr/libexec/sshd-keygen-wrapper", "/usr/bin/osascript", "/" + agent] {
      let isAgent = client == "/" + agent
      for service in ["Accessibility", "ScreenCapture", "PostEvent"]
        + (isAgent ? ["Microphone"] : [])
      {
        result.append(.init(service: "kTCCService" + service, client: client, receiver: nil))
      }
      if !isAgent {
        for receiver in ["com.apple.systemevents", "com.apple.Safari"] {
          result.append(
            .init(service: "kTCCServiceAppleEvents", client: client, receiver: receiver))
        }
      }
    }
    return result
  }

  static func schema(in binary: Data, version: Int, sha256: String) throws -> String {
    guard binary.count <= 64 << 20, (1...100).contains(version) else {
      throw MisoError.invalid("Invalid TCC schema input")
    }
    let prefix = Data("CREATE TABLE IF NOT EXISTS admin".utf8)
    let matches = Set(
      binary.split(separator: 0).filter { $0.starts(with: prefix) }.compactMap {
        String(data: Data($0), encoding: .utf8)
      }.filter {
        $0.contains("('version', \(version))") && $0.contains("CREATE TABLE IF NOT EXISTS access (")
      })
    guard matches.count == 1, let schema = matches.first,
      SafeFile.sha256(Data(schema.utf8)) == sha256
    else {
      throw MisoError.invalid("Target TCC schema differs from reviewed input")
    }
    return schema
  }

  static func seed(
    _ url: URL, schema: String, version: Int, grants: [Grant],
    preservedRequirement: Data? = nil
  ) throws -> Int {
    for suffix in ["-wal", "-shm", "-journal"] {
      var info = stat()
      guard lstat(url.path + suffix, &info) != 0, errno == ENOENT else {
        throw MisoError.invalid("TCC database has an active sidecar")
      }
    }
    if FileManager.default.fileExists(atPath: url.path) {
      let info = try FileMetadata.inspect(url)
      guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, preservedRequirement != nil else {
        throw MisoError.invalid("Existing TCC database needs an explicit merge profile")
      }
    }
    let reference = try SQLiteDatabase()
    try reference.script(schema)
    guard
      try reference.rows("SELECT value FROM admin WHERE key='version'") == [
        [.integer(Int64(version))]
      ]
    else {
      throw MisoError.invalid("TCC schema version mismatch")
    }
    let database = try SQLiteDatabase(url)
    let schemaQuery = "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"
    let existing = try database.rows(schemaQuery)
    var preserved: [[SQLiteDatabase.Value]] = []
    if existing.isEmpty {
      try database.script(schema)
    } else {
      guard existing == (try reference.rows(schemaQuery)),
        try database.rows("SELECT value FROM admin WHERE key='version'") == [
          [.integer(Int64(version))]
        ],
        let requirement = preservedRequirement
      else { throw MisoError.invalid("Existing TCC schema differs") }
      preserved = try database.rows("SELECT * FROM access")
      let expected: [[SQLiteDatabase.Value]] = [
        [
          .text("kTCCServiceScreenCapture"), .text("com.apple.screensharing.agent"),
          .integer(0), .integer(2), .integer(3), .integer(1), .blob(requirement),
        ]
      ]
      guard preserved.count == 1,
        try database.rows(
          "SELECT service,client,client_type,auth_value,auth_reason,auth_version,csreq FROM access")
          == expected
      else {
        throw MisoError.invalid("Existing TCC grant is not the declared screen-sharing seed")
      }
    }
    try database.script("BEGIN IMMEDIATE")
    do {
      for grant in grants {
        try database.rows(
          "INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,indirect_object_identifier) VALUES (?,?,1,2,0,1,?,?)",
          [
            .text(grant.service), .text(grant.client), grant.receiver == nil ? .null : .integer(0),
            .text(grant.receiver ?? "UNUSED"),
          ])
      }
      guard try database.rows("PRAGMA integrity_check") == [[.text("ok")]],
        try database.rows("SELECT count(*) FROM access") == [
          [.integer(Int64(grants.count + preserved.count))]
        ],
        try database.rows("SELECT * FROM access WHERE client='com.apple.screensharing.agent'")
          == preserved
      else {
        throw MisoError.invalid("TCC seed integrity or preservation failed")
      }
      try database.script("COMMIT")
    } catch {
      try? database.script("ROLLBACK")
      throw error
    }
    return grants.count + preserved.count
  }
}

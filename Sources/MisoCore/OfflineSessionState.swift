import Darwin
import Foundation
import Security

enum OfflineSessionState {
  static let databasePath = "Library/Application Support/com.apple.TCC/TCC.db"
  static let loginPath = "System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
  static let tccdPath = "System/Library/PrivateFrameworks/TCC.framework/Support/tccd"

  struct Profile {
    let target: MacOSRelease
    let loginSHA256: String
    let tccdSHA256: String
    let schemaSHA256: String
    let schemaVersion: Int
    let versionNumber: Int
    let buildNumber: Int

    var stamps: [String: Any] {
      [
        "SystemVersionStampAsString": target.version,
        "BuildVersionStampAsString": target.build,
        "SystemVersionStampAsNumber": versionNumber,
        "BuildVersionStampAsNumber": buildNumber,
      ]
    }
  }

  static func profile(for target: MacOSRelease) throws -> Profile? {
    let restore = try RestoreProfile.select(target)
    guard restore.family == .goldenGate else { return nil }
    let implementation: (loginSHA256: String, versionNumber: Int, buildNumber: Int)
    switch target {
    case MacOSRelease(version: "27.0", build: "26A428"):
      implementation = (
        "c5e445044388abe7e8441aef87417884771ae41da64402a8d26c8671d2d131d7",
        452_984_832, 54_539_648
      )
    case MacOSRelease(version: "27.0.1", build: "26A434"):
      implementation = (
        "59aed05e3e14eaaf551aa4cc488205a72867f385c36620f991849687ac68058d",
        452_985_088, 54_539_840
      )
    default:
      throw MisoError.unsupported("Session state needs an exact macOS 27 profile")
    }
    return Profile(
      target: target,
      loginSHA256: implementation.loginSHA256,
      tccdSHA256: "51511100c32201166912c7152302f093528344975403b1c663f7247fb95638c0",
      schemaSHA256: "f24d4076c1123e89102defbd09c860f4668147c74609644dc0e06f3be5e6d072",
      schemaVersion: 36, versionNumber: implementation.versionNumber,
      buildNumber: implementation.buildNumber)
  }

  static func screenSharingRequirement(for target: MacOSRelease) throws -> Data? {
    guard try profile(for: target) != nil else { return nil }
    var requirement: SecRequirement?
    let source = "identifier \"com.apple.screensharing.agent\" and anchor apple"
    guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw MisoError.invalid("Cannot compile the screen-sharing identity") }
    var bytes: CFData?
    guard SecRequirementCopyData(requirement, [], &bytes) == errSecSuccess, let bytes else {
      throw MisoError.invalid("Cannot encode the screen-sharing identity")
    }
    let data = bytes as Data
    guard
      SafeFile.sha256(data)
        == "971e6be9d84d2b10071c4959cbf7cb5a4662bb6a34bf82e772a3c4b2b653c43f"
    else { throw MisoError.invalid("Screen-sharing identity encoding differs") }
    return data
  }

  static func seed(_ url: URL, schema: String, version: Int, requirement: Data) throws {
    for suffix in ["-wal", "-shm", "-journal"] {
      var info = stat()
      guard lstat(url.path + suffix, &info) != 0, errno == ENOENT else {
        throw MisoError.invalid("Session TCC database has an active sidecar")
      }
    }
    if FileManager.default.fileExists(atPath: url.path) {
      let info = try FileMetadata.inspect(url)
      guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
        throw MisoError.invalid("Invalid session TCC database")
      }
    }
    let reference = try SQLiteDatabase()
    try reference.script(schema)
    let database = try SQLiteDatabase(url)
    let schemaQuery = "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"
    if try database.rows(schemaQuery).isEmpty { try database.script(schema) }
    guard try database.rows(schemaQuery) == reference.rows(schemaQuery),
      try database.rows("SELECT value FROM admin WHERE key='version'") == [
        [.integer(Int64(version))]
      ]
    else { throw MisoError.invalid("Session TCC schema differs") }
    let query =
      "SELECT * FROM access ORDER BY service,client,client_type,indirect_object_identifier"
    let other = query.replacingOccurrences(
      of: " ORDER BY", with: " WHERE client != 'com.apple.screensharing.agent' ORDER BY")
    let preserved = try database.rows(other)
    let identity = "WHERE client='com.apple.screensharing.agent'"
    let expected: [[SQLiteDatabase.Value]] = [
      [
        .text("kTCCServiceScreenCapture"), .text("com.apple.screensharing.agent"),
        .integer(0), .integer(2), .integer(3), .integer(1), .blob(requirement),
      ]
    ]
    try database.script("BEGIN IMMEDIATE")
    do {
      if try database.rows("SELECT * FROM access " + identity).isEmpty {
        try database.rows(
          "INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,flags,indirect_object_identifier_type,one_time_reprompt_eligible) VALUES ('kTCCServiceScreenCapture','com.apple.screensharing.agent',0,2,3,1,?,0,0,0)",
          [.blob(requirement)])
      }
      guard
        try database.rows(
          "SELECT service,client,client_type,auth_value,auth_reason,auth_version,csreq FROM access "
            + identity)
          == expected,
        try database.rows(other) == preserved,
        try database.rows("PRAGMA integrity_check") == [[.text("ok")]]
      else { throw MisoError.invalid("Session TCC grant or preservation differs") }
      try database.script("COMMIT")
    } catch {
      try? database.script("ROLLBACK")
      throw error
    }
  }

  static func apply(
    system: GuestVolume, data: GuestVolume, target: MacOSRelease,
    username: String, screenSharing: Bool
  ) throws -> [ImageBundle.FileRecord] {
    guard let profile = try profile(for: target) else { return [] }
    let account = try BaseImageStage.Account(username, data: data)
    guard try SafeFile.sha256(system.path(loginPath)) == profile.loginSHA256,
      try SafeFile.sha256(system.path(tccdPath)) == profile.tccdSHA256
    else { throw MisoError.invalid("Target session implementation differs") }
    let path = "Users/\(username)/Library/Preferences/loginwindow.plist"
    guard !(try data.contains(path)) else {
      throw MisoError.invalid("Existing login session state needs an explicit migration")
    }
    let schema = try BaseTCC.schema(
      in: SafeFile.read(system.path(tccdPath), limit: 64 << 20),
      version: profile.schemaVersion, sha256: profile.schemaSHA256)
    try data.mergePlist(
      path, values: profile.stamps, uid: account.uid, gid: account.gid, mode: 0o600)
    guard NSDictionary(dictionary: try data.plist(path)).isEqual(to: profile.stamps) else {
      throw MisoError.invalid("Login session state readback differs")
    }
    var files = [path]
    if screenSharing {
      let requirement = try screenSharingRequirement(for: target)!
      let url = try data.path(databasePath, createParents: true)
      try seed(url, schema: schema, version: profile.schemaVersion, requirement: requirement)
      guard chown(url.path, 0, 0) == 0, chmod(url.path, 0o600) == 0 else {
        throw MisoError.system("Set session TCC metadata", errno)
      }
      files.append(databasePath)
    }
    return try files.map { try Artifacts.record(data.path($0), relativeTo: data.root) }
  }
}

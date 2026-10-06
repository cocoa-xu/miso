import Darwin
import Foundation
import Testing

@testable import MisoCore

private func securityDatabaseURL(_ temporary: TemporaryDirectory) throws -> URL {
  guard let path = realpath(temporary.url.path, nil) else {
    throw MisoError.system("Resolve test directory", errno)
  }
  defer { free(path) }
  return URL(fileURLWithPath: String(cString: path)).appendingPathComponent("TCC.db")
}

private let securitySchema = """
  CREATE TABLE IF NOT EXISTS admin (key TEXT PRIMARY KEY, value INTEGER);
  INSERT INTO admin VALUES ('version', 32);
  CREATE TABLE IF NOT EXISTS access (
    service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, auth_reason INTEGER,
    auth_version INTEGER, csreq BLOB, indirect_object_identifier_type INTEGER,
    indirect_object_identifier TEXT, preserved INTEGER DEFAULT 42,
    PRIMARY KEY(service,client,client_type,indirect_object_identifier));
  """

@Test func tccDirectoriesKeepSharedPolicyReadableAndUserDataPrivate() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let directory = try securityDatabaseURL(temporary).deletingLastPathComponent()
  for userOwned in [false, true] {
    let expected: mode_t = userOwned ? 0o700 : 0o755
    #expect(BaseTCC.directoryMode(userOwned: userOwned) == expected)
    #expect(chmod(directory.path, expected) == 0)
    try BaseTCC.verifyDirectory(directory, uid: getuid(), gid: getgid(), userOwned: userOwned)
    #expect(throws: (any Error).self) {
      try BaseTCC.verifyDirectory(directory, uid: getuid(), gid: getgid(), userOwned: !userOwned)
    }
    #expect(throws: (any Error).self) {
      try BaseTCC.verifyDirectory(directory, uid: getuid() + 1, gid: getgid(), userOwned: userOwned)
    }
  }
  let link = directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
  #expect(throws: (any Error).self) {
    try BaseTCC.verifyDirectory(link, uid: getuid(), gid: getgid(), userOwned: true)
  }
}

@Test func sqliteBindsTypedValuesAndDeniesExternalDatabases() throws {
  let database = try SQLiteDatabase()
  try database.script("CREATE TABLE sample (i,t,b,n,r)")
  let row: [SQLiteDatabase.Value] = [
    .integer(42), .text("'; DROP TABLE sample; --"),
    .blob(Data([0, 1, 255])), .null, .real(1.25),
  ]
  try database.rows("INSERT INTO sample VALUES (?,?,?,?,?)", row)
  #expect(try database.rows("SELECT * FROM sample") == [row])
  for sql in ["ATTACH ':memory:' AS other", "SELECT 1; SELECT 2", "SELECT ?"] {
    #expect(throws: (any Error).self) { try database.rows(sql) }
  }
  #expect(throws: (any Error).self) { try database.script("ATTACH ':memory:' AS other") }
}

@Test func tccSchemaRequiresUniqueBoundVersion() throws {
  let bytes = Data(securitySchema.utf8)
  let binary = Data([0, 2, 0]) + bytes + Data([0]) + bytes + Data([0])
  #expect(
    try BaseTCC.schema(in: binary, version: 32, sha256: SafeFile.sha256(bytes)) == securitySchema)
  #expect(throws: (any Error).self) {
    try BaseTCC.schema(in: binary, version: 30, sha256: SafeFile.sha256(bytes))
  }
  #expect(throws: (any Error).self) {
    try BaseTCC.schema(in: binary, version: 32, sha256: String(repeating: "0", count: 64))
  }
  #expect(throws: (any Error).self) {
    try BaseTCC.schema(
      in: binary + Data((securitySchema + " ").utf8), version: 32, sha256: SafeFile.sha256(bytes))
  }
}

@Test func tccSeedsFourteenGrantsAndRejectsImplicitMerge() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let url = try securityDatabaseURL(temporary)
  let grants = try BaseTCC.grants(
    agent: "opt/homebrew/Cellar/tart-guest-agent/0.15.0/bin/tart-guest-agent")
  #expect(grants.count == 14)
  #expect(grants.filter { $0.service == "kTCCServiceMicrophone" }.count == 1)
  #expect(try BaseTCC.seed(url, schema: securitySchema, version: 32, grants: grants) == 14)
  #expect(throws: (any Error).self) {
    try BaseTCC.seed(url, schema: securitySchema, version: 32, grants: grants)
  }
  #expect(try SQLiteDatabase(url, readOnly: true).rows("PRAGMA integrity_check") == [[.text("ok")]])
}

@Test func tccMergePreservesDeclaredScreenSharingSeed() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let url = try securityDatabaseURL(temporary)
  let requirement = Data([1, 2, 3])
  do {
    let database = try SQLiteDatabase(url)
    try database.script(securitySchema)
    try database.rows(
      "INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,indirect_object_identifier) VALUES ('kTCCServiceScreenCapture','com.apple.screensharing.agent',0,2,3,1,?,'UNUSED')",
      [.blob(requirement)])
  }
  let grants = try BaseTCC.grants(
    agent: "opt/homebrew/Cellar/tart-guest-agent/0.15.0/bin/tart-guest-agent")
  #expect(throws: (any Error).self) {
    try BaseTCC.seed(
      url, schema: securitySchema, version: 32, grants: grants, preservedRequirement: Data([9]))
  }
  #expect(
    try BaseTCC.seed(
      url, schema: securitySchema, version: 32, grants: grants, preservedRequirement: requirement)
      == 15)
  #expect(
    try SQLiteDatabase(url, readOnly: true).rows(
      "SELECT preserved FROM access WHERE client='com.apple.screensharing.agent'") == [
        [.integer(42)]
      ])
}

@Test func tccRejectsDanglingSidecars() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let url = try securityDatabaseURL(temporary)
  try FileManager.default.createSymbolicLink(
    atPath: url.path + "-wal", withDestinationPath: "missing")
  #expect(throws: (any Error).self) {
    try BaseTCC.seed(url, schema: securitySchema, version: 32, grants: [])
  }
}

@Test func basePolicyOverridesRequireExplicitModeAndKeepAuthenticatedRoot() throws {
  let keys = [
    "BORD", "CHIP", "CPRO", "CSEC", "ECID", "SDOM", "CEPO", "lobo", "lpnh", "rpnh", "nsih", "vuid",
    "love", "kuid", "hrlp", "spih", "stng",
  ]
  let vanilla = Dictionary(uniqueKeysWithValues: keys.map { ($0, DER.integer(1)) })
  try LocalPolicy.validate(vanilla, mode: .standard)
  var base = vanilla
  base["sip0"] = DER.integer(127)
  for key in ["sip2", "sip3", "smb0", "smb1"] { base[key] = DER.encode(1, Data([255])) }
  try LocalPolicy.validate(base, mode: .base)
  #expect(throws: (any Error).self) { try LocalPolicy.validate(base, mode: .standard) }
  #expect(throws: (any Error).self) { try LocalPolicy.validate(vanilla, mode: .base) }
  base["sip0"] = DER.integer(0xFFF)
  #expect(throws: (any Error).self) { try LocalPolicy.validate(base, mode: .base) }
}

@Test func guestDirectoriesDoNotInheritRestrictiveUmask() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  try volume.makeDirectories("parent/child", uid: getuid(), gid: getgid())
  #expect(try FileMetadata.inspect(volume.path("parent")).st_mode & 0o777 == 0o755)
  #expect(try FileMetadata.inspect(volume.path("parent/child")).st_mode & 0o777 == 0o755)
  try FileManager.default.createSymbolicLink(
    atPath: temporary.url.appendingPathComponent("link").path, withDestinationPath: "parent")
  #expect(throws: (any Error).self) {
    try volume.makeDirectories("link/escape", uid: getuid(), gid: getgid())
  }
}

@Test @MainActor func securityProbeAcceptsOnlySystemCookieAliases() {
  for prefix in ["/var", "/private/var", "//var", "///private/var"] {
    #expect(
      BaseSecurity.validProbeIdentity(
        [
          "home": "/Users/admin",
          "automation_cookie_path": prefix + "/db/com.apple.dt.automationmode/no-auth-required",
        ], home: "/Users/admin"))
  }
  #expect(
    !BaseSecurity.validProbeIdentity(
      [
        "home": "/Users/other",
        "automation_cookie_path": "/var/db/com.apple.dt.automationmode/no-auth-required",
      ], home: "/Users/admin"))
  #expect(
    !BaseSecurity.validProbeIdentity(
      [
        "home": "/Users/admin",
        "automation_cookie_path": "/tmp/no-auth-required",
      ], home: "/Users/admin"))
  for cookie in [
    "var/db/com.apple.dt.automationmode/no-auth-required",
    "//server/var/db/com.apple.dt.automationmode/no-auth-required",
    "/var/../var/db/com.apple.dt.automationmode/no-auth-required",
  ] {
    #expect(
      !BaseSecurity.validProbeIdentity(
        ["home": "/Users/admin", "automation_cookie_path": cookie], home: "/Users/admin"))
  }
}

@Test func baseSecurityBindsMountedBootInputsWithoutRetainedTree() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let path = try Artifacts.makeParents(for: "group/boot/active", under: temporary.url)
  try SafeFile.writeNew(Data("manifest".utf8), to: path)
  let record = ImageBundle.FileRecord(
    path: "Preboot/group/boot/active", bytes: 8, sha256: SafeFile.sha256(Data("manifest".utf8)))
  let mounts = ["Preboot": try GuestVolume(temporary.url)]
  #expect(
    try BaseBootSecurity.readBound(record, mounts: mounts, limit: 128) == Data("manifest".utf8))
  try Data("changed!".utf8).write(to: path)
  #expect(throws: (any Error).self) {
    try BaseBootSecurity.readBound(record, mounts: mounts, limit: 128)
  }
}

@MainActor
@Test func recoveredParentInputsBindTargetBlobsAndJournal() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("parent")
  let journal = try ExecutionJournal(output: output, operation: "prepare-base-parent")
  var blobs: [String: ImageBundle.FileRecord] = [:]
  for name in ["key", "certificates", "payload"] {
    let file = output.appendingPathComponent(name + ".der")
    try SafeFile.writeNew(Data(name.utf8), to: file)
    blobs[name] = try Artifacts.record(file, relativeTo: output)
  }
  let target = MacOSRelease(version: "27.0.1", build: "26A434")
  let receipt = BaseParentInputs.Receipt(
    schemaVersion: 1, sourceManifest: blobs["payload"]!,
    boot: .init(
      target: target, volumeGroup: UUID(), nsih: String(repeating: "A", count: 96),
      spih: String(repeating: "B", count: 96), files: []),
    blobs: blobs, originalsUnchanged: true, vmStarted: false)
  try journal.finish(receipt)
  let inputs = try BaseBootSecurity.Inputs(boot: output, material: output, target: target)
  #expect(try inputs.blob("key") == Data("key".utf8))
  #expect(throws: (any Error).self) {
    try BaseBootSecurity.Inputs(
      boot: output, material: output, target: .init(version: "26.6", build: "25G83"))
  }
  try SafeFile.replace(Data("changed".utf8), at: output.appendingPathComponent("key.der"))
  #expect(throws: (any Error).self) { try inputs.blob("key") }
  try SafeFile.replace(Data("{}".utf8), at: output.appendingPathComponent("journal.json"))
  #expect(throws: (any Error).self) { try inputs.verifyJournal() }
}

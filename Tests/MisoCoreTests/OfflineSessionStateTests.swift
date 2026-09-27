import Foundation
import Testing

@testable import MisoCore

private let sessionTarget = MacOSRelease(version: "27.0", build: "26A428")
private let sessionSchema = """
  CREATE TABLE IF NOT EXISTS admin (key TEXT PRIMARY KEY, value INTEGER);
  INSERT INTO admin VALUES ('version', 36);
  CREATE TABLE IF NOT EXISTS access (
    service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, auth_reason INTEGER,
    auth_version INTEGER, csreq BLOB, flags INTEGER, one_time_reprompt_eligible INTEGER,
    indirect_object_identifier_type INTEGER, indirect_object_identifier TEXT DEFAULT 'UNUSED',
    PRIMARY KEY(service,client,client_type,indirect_object_identifier));
  """

@Test func sessionProfilesBindOnlyReviewedReleasesAndCodeIdentity() throws {
  let profile = try #require(try OfflineSessionState.profile(for: sessionTarget))
  #expect(profile.stamps["SystemVersionStampAsString"] as? String == "27.0")
  #expect(profile.stamps["BuildVersionStampAsString"] as? String == "26A428")
  #expect(profile.stamps["SystemVersionStampAsNumber"] as? Int == 452_984_832)
  #expect(profile.stamps["BuildVersionStampAsNumber"] as? Int == 54_539_648)
  let requirement = try #require(
    try OfflineSessionState.screenSharingRequirement(for: sessionTarget))
  #expect(requirement.count == 60)
  for target in [
    MacOSRelease(version: "15.6.1", build: "24G90"), .init(version: "26.6.2", build: "25G83"),
  ] {
    #expect(try OfflineSessionState.profile(for: target) == nil)
    #expect(try OfflineSessionState.screenSharingRequirement(for: target) == nil)
  }
  #expect(throws: (any Error).self) {
    try OfflineSessionState.profile(for: .init(version: "27.0", build: "26A999"))
  }
}

@Test func sessionCaptureGrantSurvivesBaseSeedingAndIsIdempotent() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let path = temporary.url.appendingPathComponent("TCC.db")
  let requirement = try #require(
    try OfflineSessionState.screenSharingRequirement(for: sessionTarget))
  try OfflineSessionState.seed(path, schema: sessionSchema, version: 36, requirement: requirement)
  let grants = try BaseTCC.grants(
    agent: "opt/homebrew/Cellar/tart-guest-agent/0.15.0/bin/tart-guest-agent")
  #expect(
    try BaseTCC.seed(
      path, schema: sessionSchema, version: 36, grants: grants, preservedRequirement: requirement)
      == 15)
  let before = try SQLiteDatabase(path, readOnly: true).rows(
    "SELECT * FROM access ORDER BY service,client")
  try OfflineSessionState.seed(path, schema: sessionSchema, version: 36, requirement: requirement)
  #expect(
    try SQLiteDatabase(path, readOnly: true).rows("SELECT * FROM access ORDER BY service,client")
      == before)
}

@Test func sessionCaptureMergePreservesExistingBaseGrants() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let path = temporary.url.appendingPathComponent("TCC.db")
  let grants = try BaseTCC.grants(
    agent: "opt/homebrew/Cellar/tart-guest-agent/0.15.0/bin/tart-guest-agent")
  #expect(try BaseTCC.seed(path, schema: sessionSchema, version: 36, grants: grants) == 14)
  let query =
    "SELECT * FROM access WHERE client!='com.apple.screensharing.agent' ORDER BY service,client"
  let before = try SQLiteDatabase(path, readOnly: true).rows(query)
  let requirement = try #require(
    try OfflineSessionState.screenSharingRequirement(for: sessionTarget))
  try OfflineSessionState.seed(path, schema: sessionSchema, version: 36, requirement: requirement)
  #expect(try SQLiteDatabase(path, readOnly: true).rows(query) == before)
  #expect(
    try SQLiteDatabase(path, readOnly: true).rows("SELECT count(*) FROM access") == [[.integer(15)]]
  )
}

@Test func sessionCaptureMergeRejectsChangedIdentityAndActiveSidecars() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let path = temporary.url.appendingPathComponent("TCC.db")
  let requirement = try #require(
    try OfflineSessionState.screenSharingRequirement(for: sessionTarget))
  try OfflineSessionState.seed(path, schema: sessionSchema, version: 36, requirement: requirement)
  try SQLiteDatabase(path).rows("UPDATE access SET auth_value=1")
  let before = try SafeFile.sha256(path)
  #expect(throws: (any Error).self) {
    try OfflineSessionState.seed(path, schema: sessionSchema, version: 36, requirement: requirement)
  }
  #expect(try SafeFile.sha256(path) == before)
  try SafeFile.writeNew(Data(), to: URL(fileURLWithPath: path.path + "-wal"))
  #expect(throws: (any Error).self) {
    try OfflineSessionState.seed(path, schema: sessionSchema, version: 36, requirement: requirement)
  }
}

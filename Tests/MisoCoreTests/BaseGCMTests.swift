import Foundation
import Testing

@testable import MisoCore

private func gcmPlan(version: String = "2.9.1") -> BaseGCMInputs.Plan {
  func record(_ path: String) -> ImageBundle.FileRecord {
    .init(path: path, bytes: 100, sha256: String(repeating: "a", count: 64))
  }
  return .init(
    schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"), version: version,
    package: record("gcm.pkg"), recipe: record("gcm.rb"), metadata: record("gcm.json"))
}

@Test func credentialManagerPlansBindIndependentInputs() throws {
  try gcmPlan().validate()
  try gcmPlan(version: "3.10.42").validate()
  for version in ["latest", "2.9.1';system('id')", "2.9.1\n", "../2.9.1"] {
    #expect(throws: (any Error).self) { try gcmPlan(version: version).validate() }
  }
  let plan = gcmPlan()
  let metadata = BaseGCMInputs.Metadata(
    version: plan.version, sha256: plan.package.sha256,
    tapRevision: String(repeating: "b", count: 40),
    recipeChecksum: .init(sha256: plan.recipe.sha256))
  try metadata.validate(plan)
  #expect(throws: (any Error).self) { try metadata.validate(gcmPlan(version: "2.9.2")) }
}

@Test func credentialManagerBOMRejectsEscapesLinksAndPrivilegedModes() throws {
  let root = ".\t40755\t0\t0\t\t\n"
  let binary = "./git-credential-manager\t100755\t0\t0\t100\t\n"
  #expect(try BaseGCMPackage.parseBOM(root + binary).count == 1)
  for row in [
    "./../escape\t100644\t0\t0\t1\t\n",
    "./link\t120755\t0\t0\t1\t/etc\n", "./suid\t104755\t0\t0\t1\t\n",
    "./foreign\t100644\t501\t20\t1\t\n", "./empty\t100644\t0\t0\t\t\n",
    "./missing/file\t100644\t0\t0\t1\t\n", binary, root,
  ] {
    #expect(throws: (any Error).self) { try BaseGCMPackage.parseBOM(root + binary + row) }
  }
  #expect(throws: (any Error).self) { try BaseGCMPackage.parseBOM(binary) }
}

@Test func credentialManagerPackageIdentityCannotChangeNamespace() throws {
  let xml = """
    <pkg-info identifier="com.microsoft.gitcredentialmanager" version="2.9.1" install-location="/usr/local/share/gcm-core"/>
    """
  try BaseGCMPackage.validateInfo(Data(xml.utf8), version: "2.9.1")
  for invalid in [
    xml.replacingOccurrences(of: "gcm-core", with: "../bin"),
    xml.replacingOccurrences(of: "gitcredentialmanager", with: "other"),
    xml.replacingOccurrences(of: "2.9.1", with: "2.9.2"),
  ] {
    #expect(throws: (any Error).self) {
      try BaseGCMPackage.validateInfo(Data(invalid.utf8), version: "2.9.1")
    }
  }
}

@Test func credentialManagerCaskRegistrationBindsIdentityWithoutRunningInstaller() throws {
  let revision = String(repeating: "b", count: 40)
  let program = try BaseGCM.registrationProgram(gcmPlan(), tapRevision: revision, username: "admin")
  #expect(program.contains("c.sha256.to_s == '" + gcmPlan().package.sha256))
  #expect(program.contains("c.version.to_s == '2.9.1'"))
  #expect(!program.contains(".install"))
  for user in ["root'; abort 'bad", "../admin", "admin\n"] {
    #expect(throws: (any Error).self) {
      try BaseGCM.registrationProgram(gcmPlan(), tapRevision: revision, username: user)
    }
  }
}

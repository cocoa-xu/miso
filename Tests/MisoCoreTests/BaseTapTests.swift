import Foundation
import Testing

@testable import MisoCore

private let tapRecord = ImageBundle.FileRecord(
  path: "payload.tar.gz", bytes: 100, sha256: String(repeating: "a", count: 64))

private func tapFixture(
  name: String = "vendor/tools", path: String = "checkout",
  revision: String = String(repeating: "b", count: 40)
) -> BaseTapInputs.Tap {
  .init(
    name: name, revision: revision, resource: "sources", path: path,
    formulas: [.init(name: "example@3", version: "3.2.1", revision: 2, payload: tapRecord)])
}

@Test func tapPlansRejectUnsafeAndDuplicateInputs() throws {
  func plan(_ taps: [BaseTapInputs.Tap]) -> BaseTapInputs.Plan {
    .init(
      schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"), archive: tapRecord,
      taps: taps)
  }
  try plan([tapFixture()]).validate()
  #expect(tapFixture().destination == "opt/homebrew/Library/Taps/vendor/homebrew-tools")
  #expect(tapFixture().formulas[0].kegVersion == "3.2.1_2")
  for taps in [
    [], [tapFixture(), tapFixture()], [tapFixture(), tapFixture(name: "another/tools")],
    [tapFixture(name: "../tools")], [tapFixture(path: "../checkout")],
    [tapFixture(revision: "HEAD")],
  ] {
    #expect(throws: (any Error).self) { try plan(taps).validate() }
  }
}

@Test func tapSubtreesRequireContainedGitSnapshots() throws {
  let directory = BaseInputArchive.Entry(
    path: "checkout", kind: "directory", mode: 0o755, bytes: nil, sha256: nil, link: nil)
  let head = BaseInputArchive.Entry(
    path: "checkout/.git/HEAD", kind: "file", mode: 0o644, bytes: 41, sha256: tapRecord.sha256,
    link: nil)
  let outside = BaseInputArchive.Entry(
    path: "checkout-other/file", kind: "file", mode: 0o644, bytes: 1, sha256: tapRecord.sha256,
    link: nil)
  #expect(
    try BaseTapInputs.subtree([outside, head, directory], path: "checkout").map(\.path) == [
      ".", ".git/HEAD",
    ])
  #expect(throws: (any Error).self) { try BaseTapInputs.subtree([directory], path: "checkout") }
  let link = BaseInputArchive.Entry(
    path: "checkout/link", kind: "symlink", mode: 0o755, bytes: nil, sha256: nil, link: "/outside")
  #expect(throws: (any Error).self) {
    try BaseTapInputs.subtree([directory, head, link], path: "checkout")
  }
}

@Test func tapCachePathsBindAccountAndDigestName() throws {
  let path =
    "/Users/admin/Library/Caches/Homebrew/downloads/" + String(repeating: "a", count: 64)
    + "--package_3.2+arm64.tar.gz"
  #expect(try BaseTaps.cachePath(path, username: "admin") == String(path.dropFirst()))
  for invalid in [
    path + "/outside", path + "\n", path.replacingOccurrences(of: "admin", with: "another"),
    path.replacingOccurrences(of: "downloads/", with: "downloads/../"), "/opt/homebrew/payload",
  ] {
    #expect(throws: (any Error).self) { try BaseTaps.cachePath(invalid, username: "admin") }
  }
  #expect(throws: (any Error).self) { try BaseTaps.cachePath(path, username: ".*") }
}

@Test func tapInstallAdapterRequiresOuterIsolationBeforeChangingNestedSandbox() throws {
  let program = try BaseTaps.installProgram(fullName: "vendor/tools/example@3", uid: 501, gid: 20)
  #expect(program.contains("Process.euid == 501"))
  #expect(program.contains("[[], [20]].include?(ids)"))
  #expect(program.contains("check.call(Process.pid, nil, 0) == 1"))
  let guardRange = try #require(program.range(of: "raise 'Missing outer isolation'"))
  let adapterRange = try #require(program.range(of: "Sandbox.singleton_class.prepend"))
  #expect(guardRange.lowerBound < adapterRange.lowerBound)
  let child = try BaseTaps.isolationProgram(uid: 501, gid: 20)
  #expect(child.contains("args.concat(['-r', __FILE__])"))
  #expect(child.contains("Object.const_set(:HOMEBREW_RUBY_EXEC_ARGS, args.freeze)"))
  #expect(!program.contains("args.concat"))
  for name in ["vendor/tools/name'; abort 'injected", "vendor/../name", "vendor/tools/name/extra"] {
    #expect(throws: (any Error).self) {
      try BaseTaps.installProgram(fullName: name, uid: 501, gid: 20)
    }
  }
  #expect(throws: (any Error).self) {
    try BaseTaps.installProgram(fullName: "vendor/tools/example", uid: 0, gid: 20)
  }
}

import Foundation
import Testing

@testable import MisoCore

private final class NoGitNetwork: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    Issue.record("Cached Git replay attempted a network request")
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
}

private struct SnapshotFixture {
  var pack = PackFixture()

  mutating func object(_ type: UInt8, _ name: String, _ data: Data) throws -> Data {
    _ = try pack.append(type, data)
    return PackFixture.id(data, type: name)
  }

  mutating func tree(_ entries: [(UInt32, String, Data)]) throws -> Data {
    var data = Data()
    for (mode, path, id) in entries {
      data.append(Data((String(mode, radix: 8) + " " + path + "\0").utf8) + id)
    }
    return try object(2, "tree", data)
  }

  mutating func commit(_ tree: Data) throws -> GitRemote.Selection {
    let data = Data(
      """
      tree \(SafeFile.hex(tree))
      author Cocoa <i@uwucocoa.moe> 1 +0000
      committer Cocoa <i@uwucocoa.moe> 1 +0000

      Fixture

      """.utf8)
    let id = SafeFile.hex(try object(1, "commit", data))
    return GitRemote.Selection(reference: "HEAD", objectID: id, commitID: id)
  }
}

private func capabilities(_ fetch: String = "shallow", format: String = "sha1") throws -> Data {
  try GitRemote.packet("version 2\n") + GitRemote.packet("ls-refs\n")
    + GitRemote.packet("fetch=\(fetch)\n") + GitRemote.packet("object-format=\(format)\n")
    + Data("0000".utf8)
}

private func advertisement(_ selection: GitRemote.Selection) throws -> Data {
  try GitRemote.packet("\(selection.commitID) HEAD symref-target:refs/heads/main\n")
    + GitRemote.packet("\(selection.objectID) refs/tags/1.0.0 peeled:\(selection.commitID)\n")
    + Data("0000".utf8)
}

@Test func gitAdvertisementSelectsCommitAndAnnotatedTag() throws {
  let selected = GitRemote.Selection(
    reference: "refs/tags/1.0.0", objectID: String(repeating: "a", count: 40),
    commitID: String(repeating: "b", count: 40))
  let remote = try GitRemote(capabilities: capabilities(), references: advertisement(selected))
  try GitRemote.validateCapabilities(
    GitRemote.packet("# service=git-upload-pack\n") + Data("0000".utf8) + capabilities())
  #expect(try remote.select(selected.reference) == selected)
  #expect(try remote.select(nil).objectID == selected.commitID)
  let request = try remote.request(selected)
  var cursor = GitPack.Cursor(data: request)
  #expect(try GitRemote.line(&cursor) == "command=fetch\n")
  #expect(try GitRemote.read(&cursor) == .delimiter)
  #expect(try GitRemote.line(&cursor) == "want \(selected.objectID)\n")
  #expect(try GitRemote.line(&cursor) == "deepen 1\n")
  #expect(try GitRemote.line(&cursor) == "no-progress\n")
  #expect(try GitRemote.line(&cursor) == "ofs-delta\n")
  #expect(try GitRemote.line(&cursor) == "done\n")
  #expect(try GitRemote.line(&cursor) == nil)
  #expect(cursor.offset == request.count)
  #expect(throws: MisoError.self) { try remote.select("refs/tags/missing") }
  #expect(throws: MisoError.self) {
    try remote.request(
      GitRemote.Selection(
        reference: "HEAD", objectID: selected.objectID, commitID: selected.commitID))
  }
}

@Test func gitProtocolRejectsMalformedPacketsAndCapabilities() throws {
  let selection = GitRemote.Selection(
    reference: "HEAD", objectID: String(repeating: "a", count: 40),
    commitID: String(repeating: "a", count: 40))
  let valid = try advertisement(selection)
  for value in [
    Data(), Data("zzzz".utf8), Data("0001".utf8), Data("0008x".utf8), valid + Data([0]),
    Data(valid.dropLast()),
  ] {
    #expect(throws: MisoError.self) {
      try GitRemote(capabilities: capabilities(), references: value)
    }
  }
  for value in [try capabilities(""), try capabilities(format: "sha256")] {
    #expect(throws: MisoError.self) {
      try GitRemote(capabilities: value, references: advertisement(selection))
    }
  }
  for name in [
    "refs/../config", "refs/heads/.hidden", "refs/heads/main.lock", "refs/heads/one\n",
    "refs//main", "refs/heads/main^{}", "../HEAD",
  ] {
    #expect(throws: MisoError.self) { try GitRemote.validateReference(name) }
  }
  for repository in [
    "../brew", "Homebrew/brew.git", "Homebrew/brew?foo", "Homebrew/brew/extra",
    "https://github.com/Homebrew/brew",
  ] {
    #expect(throws: MisoError.self) { try GitRemote.repositoryURL(repository) }
  }
}

@Test func gitResponseBindsShallowBoundary() throws {
  let selection = GitRemote.Selection(
    reference: "HEAD", objectID: String(repeating: "a", count: 40),
    commitID: String(repeating: "a", count: 40))
  let pack = Data("PACKfixture".utf8)
  let prefix =
    try GitRemote.packet("shallow-info\n") + GitRemote.packet("shallow \(selection.commitID)")
    + Data("0001".utf8)
    + GitRemote.packet("packfile\n")
  #expect(
    try GitRemote.response(
      prefix + GitRemote.packet(Data([1]) + pack) + Data("0000".utf8), selection: selection) == pack
  )
  for response in [
    try GitRemote.packet("shallow \(String(repeating: "b", count: 40))\n") + Data("0000".utf8),
    try Data("0000".utf8) + GitRemote.packet("ACK \(selection.commitID)\n") + pack,
    prefix + Data("not-a-pack".utf8),
  ] {
    #expect(throws: MisoError.self) { try GitRemote.response(response, selection: selection) }
  }
}

@Test func gitCheckoutCreatesARealCleanRepository() throws {
  var fixture = SnapshotFixture()
  let file = try fixture.object(3, "blob", Data("hello\n".utf8))
  let script = try fixture.object(3, "blob", Data("#!/bin/sh\nexit 0\n".utf8))
  let link = try fixture.object(3, "blob", Data("file".utf8))
  let sub = try fixture.tree([(0o100755, "run", script)])
  let tree = try fixture.tree([
    (0o100644, "file", file), (0o120000, "link", link), (0o40000, "sub", sub),
  ])
  let commit = try fixture.commit(tree)
  let tag = try fixture.object(
    4, "tag", Data("object \(commit.commitID)\ntype commit\ntag 1.0.0\n\nFixture\n".utf8))
  let selection = GitRemote.Selection(
    reference: "refs/tags/1.0.0", objectID: SafeFile.hex(tag), commitID: commit.commitID)
  let pack = try GitPack(fixture.pack.data)
  let checkout = try GitCheckout(pack: pack, selection: selection)
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let output = temporary.url.appendingPathComponent("checkout")
  try checkout.write(to: output, pack: pack, origin: GitRemote.repositoryURL("fixture/repo"))
  #expect(
    try FileManager.default.destinationOfSymbolicLink(
      atPath: output.appendingPathComponent("link").path) == "file")
  for arguments in [["status", "--porcelain", "--untracked-files=all"], ["fsck", "--strict"]] {
    let log = temporary.url.appendingPathComponent(arguments[0])
    let out = try SafeFile.create(log)
    let err = try SafeFile.create(log.appendingPathExtension("err"))
    defer {
      try? out.close()
      try? err.close()
    }
    let result = try NativeProcess.run(
      NativeCommand(
        "/usr/bin/git", arguments: ["-C", output.path] + arguments, timeout: 15,
        environment: [
          "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0",
        ]),
      stdout: out, stderr: err)
    #expect(result.succeeded)
    #expect(try SafeFile.read(log, limit: 4096).isEmpty)
  }
}

@Test func gitCheckoutRejectsUnsafeTreesBeforeWriting() throws {
  for name in [".git", ".GIT", ".g\u{200c}it", "../escape", "a/b", "a:b", ""] {
    var fixture = SnapshotFixture()
    let file = try fixture.object(3, "blob", Data([1]))
    let tree = try fixture.tree([(0o100644, name, file)])
    let selection = try fixture.commit(tree)
    let pack = try GitPack(fixture.pack.data)
    #expect(throws: MisoError.self) { try GitCheckout(pack: pack, selection: selection) }
  }
  for pair in [["file", "FILE"], ["é", "e\u{301}"]] {
    var fixture = SnapshotFixture()
    let file = try fixture.object(3, "blob", Data([1]))
    let tree = try fixture.tree(pair.map { (0o100644, $0, file) })
    let selection = try fixture.commit(tree)
    let pack = try GitPack(fixture.pack.data)
    #expect(throws: MisoError.self) { try GitCheckout(pack: pack, selection: selection) }
  }
  for destination in ["../escape", "/tmp/escape", "link"] {
    var fixture = SnapshotFixture()
    let link = try fixture.object(3, "blob", Data(destination.utf8))
    let tree = try fixture.tree([(0o120000, "link", link)])
    let selection = try fixture.commit(tree)
    let pack = try GitPack(fixture.pack.data)
    #expect(throws: MisoError.self) { try GitCheckout(pack: pack, selection: selection) }
  }
}

@Test func gitSnapshotReplaysWithoutNetworkAndRejectsTampering() async throws {
  var fixture = SnapshotFixture()
  let file = try fixture.object(3, "blob", Data("fixture\n".utf8))
  let tree = try fixture.tree([(0o100644, "file", file)])
  let selection = try fixture.commit(tree)
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let cache = temporary.url.appendingPathComponent("cache")
  try SafeFile.makeDirectory(cache)
  let response =
    try GitRemote.packet("packfile\n")
    + GitRemote.packet(Data([1]) + fixture.pack.data) + Data("0000".utf8)
  for (name, data) in [
    ("capabilities.bin", try capabilities()), ("advertisement.bin", try advertisement(selection)),
    ("response.bin", response),
  ] { try SafeFile.writeNew(data, to: cache.appendingPathComponent(name)) }
  let receipt = try GitSnapshot.Receipt(
    schemaVersion: 1, repository: "fixture/repo", selection: selection,
    capabilities: Artifacts.record(
      cache.appendingPathComponent("capabilities.bin"), relativeTo: cache),
    advertisement: Artifacts.record(
      cache.appendingPathComponent("advertisement.bin"), relativeTo: cache),
    response: Artifacts.record(cache.appendingPathComponent("response.bin"), relativeTo: cache))
  try SafeFile.writeNew(JSON.encode(receipt), to: cache.appendingPathComponent("snapshot.json"))
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [NoGitNetwork.self]
  let replay = try await GitSnapshot.run(
    repository: "fixture/repo", expectedCommit: selection.commitID,
    output: temporary.url.appendingPathComponent("replay"), cache: cache,
    configuration: configuration)
  #expect(replay == receipt)
  let pinned = GitRemote.Selection(
    reference: "refs/tags/1.0.0", objectID: selection.objectID, commitID: selection.commitID)
  let pinnedReceipt = GitSnapshot.Receipt(
    schemaVersion: 1, repository: receipt.repository, selection: pinned,
    capabilities: receipt.capabilities, advertisement: receipt.advertisement,
    response: receipt.response)
  try SafeFile.replace(
    JSON.encode(pinnedReceipt), at: cache.appendingPathComponent("snapshot.json"))
  let pinnedReplay = try await GitSnapshot.run(
    repository: "fixture/repo", reference: pinned.reference,
    expectedCommit: pinned.commitID, pinned: pinned,
    output: temporary.url.appendingPathComponent("pinned"), cache: cache,
    configuration: configuration)
  #expect(pinnedReplay == pinnedReceipt)
  try SafeFile.replace(JSON.encode(receipt), at: cache.appendingPathComponent("snapshot.json"))
  await #expect(throws: MisoError.self) {
    try await GitSnapshot.run(
      repository: "fixture/repo", expectedCommit: String(repeating: "a", count: 40),
      output: temporary.url.appendingPathComponent("wrong-commit"), cache: cache,
      configuration: configuration)
  }
  try SafeFile.replace(response + Data([0]), at: cache.appendingPathComponent("response.bin"))
  await #expect(throws: MisoError.self) {
    try await GitSnapshot.run(
      repository: "fixture/repo",
      output: temporary.url.appendingPathComponent("tampered"), cache: cache,
      configuration: configuration)
  }
}

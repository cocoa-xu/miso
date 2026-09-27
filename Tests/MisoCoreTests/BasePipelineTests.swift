import Darwin
import Foundation
import Testing

@testable import MisoCore

private func buildRecipe() -> BaseBuildRecipe {
  BaseBuildRecipe(
    schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"), username: "admin",
    steps: BaseBuildRecipe.Stage.allCases.map { stage in
      .init(
        stage: stage,
        files: Dictionary(
          uniqueKeysWithValues: stage.fileKeys.map { key in
            (
              key,
              .init(
                path: stage == .bootstrap
                  ? "bootstrap/archive.json"
                  : stage == .bottles ? "bottles/resolution.json" : stage.rawValue + "-" + key,
                bytes: 1,
                sha256: String(repeating: "a", count: 64))
            )
          }),
        directories: Dictionary(
          uniqueKeysWithValues: stage.directoryKeys.map { ($0, "resources") }),
        formulae: stage == .bottles ? ["git", "node@24"] : nil)
    })
}

@Test func baseRecipeRequiresEveryStageExactlyOnceInOrder() throws {
  let recipe = buildRecipe()
  try recipe.validate()
  for steps in [
    Array(recipe.steps.dropLast()), recipe.steps.reversed(), recipe.steps + [recipe.steps[0]],
  ] {
    let invalid = BaseBuildRecipe(
      schemaVersion: 1, target: recipe.target, username: "admin", steps: Array(steps))
    #expect(throws: (any Error).self) { try invalid.validate() }
  }
  let original = recipe.steps[0]
  var files = original.files
  files["source"] = original.files["runner"]
  #expect(throws: (any Error).self) {
    try BaseBuildRecipe.Step(stage: .static, files: files, directories: [:], formulae: nil)
      .validate()
  }
  #expect(throws: (any Error).self) {
    try BaseBuildRecipe.Step(
      stage: .bootstrap, files: [:], directories: ["archive": "../outside"], formulae: nil
    ).validate()
  }
}

@Test func baseRecipeArgumentsAreTypedAndDoNotInvokeAShell() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let volume = try GuestVolume(temporary.url)
  try volume.makeDirectories("resources", uid: getuid(), gid: getgid())
  try volume.makeDirectories("bootstrap", uid: getuid(), gid: getgid())
  try volume.makeDirectories("bottles", uid: getuid(), gid: getgid())
  let recipe = buildRecipe()
  for step in recipe.steps {
    let arguments = try recipe.arguments(for: step, inputs: volume, nodeFormula: "node@24")
    #expect(Array(arguments.prefix(step.stage.command.count)) == step.stage.command)
    #expect(arguments.contains("--username") == (step.stage != .settings))
    #expect(arguments.contains("--post-install") == (step.stage == .bottles))
    #expect(!arguments.contains("/bin/sh"))
    #expect(!arguments.contains("--source"))
    #expect(!arguments.contains("--output"))
    if step.stage == .static {
      #expect(arguments.contains("--runner-release"))
      #expect(!arguments.contains("--release"))
    }
  }
}

@Test @MainActor func baseBuildRejectsBootedMismatchedAndPartialSources() throws {
  let target = MacOSRelease(version: "26.6.2", build: "25G83")
  let manifest: [String: Any] = [
    "construction_vm_started": false, "runtime_verified": false,
    "target": ["version": target.version, "build": target.build],
  ]
  try BasePipeline.requireVanilla(JSONSerialization.data(withJSONObject: manifest), target: target)
  for (key, value) in [
    ("construction_vm_started", true), ("runtime_verified", true), ("base_complete", true),
    ("base_stages", ["base-static"]), ("base_stages", "invalid"),
    ("target", ["version": "15.6.1", "build": "24G90"]),
  ] as [(String, Any)] {
    var invalid = manifest
    invalid[key] = value
    #expect(throws: (any Error).self) {
      try BasePipeline.requireVanilla(
        JSONSerialization.data(withJSONObject: invalid), target: target)
    }
  }
}

@Test func stageWorkspaceRejectsMountedFilesystems() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  try BaseStageWorkspace.requireUnmounted(temporary.url)
  #expect(throws: (any Error).self) {
    try BaseStageWorkspace.requireUnmounted(URL(fileURLWithPath: "/"))
  }
}

@Test func baseBuildCommandNamesSatisfyTheJournalContract() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let journal = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("run"), operation: "test-base-command-names")
  for name in BaseBuildRecipe.Stage.allCases.map(\.operation) + ["base-cleanup"] {
    try journal.run(name, NativeCommand("/bin/echo", arguments: ["accepted"]))
  }
  #expect(journal.record.commands.count == 11)
}

@Test func completedStagePruningPreservesEvidenceAndDoesNotFollowLinks() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let outer = try ExecutionJournal(
    output: temporary.url.appendingPathComponent("build"), operation: "base-build")
  let stage = outer.output.appendingPathComponent("01-static")
  let child = try ExecutionJournal(output: stage, operation: "base-static")
  let volume = try GuestVolume(stage)
  try volume.makeDirectories("bundle", uid: getuid(), gid: getgid())
  try volume.write("bundle/disk.img", data: Data("fixture".utf8), uid: getuid(), gid: getgid())
  try volume.makeDirectories("execution-root/nested", uid: getuid(), gid: getgid())
  let sentinel = temporary.url.appendingPathComponent("preserved")
  try SafeFile.writeNew(Data("keep".utf8), to: sentinel)
  #expect(symlink(sentinel.path, try volume.path("execution-root/link").path) == 0)
  #expect(throws: (any Error).self) {
    try BaseStageWorkspace.prune(stage, image: true, journal: outer)
  }
  #expect(try volume.contains("bundle/disk.img"))
  try child.finish(["accepted": true])
  try BaseStageWorkspace.prune(stage, image: false, journal: outer)
  #expect(try !volume.contains("execution-root"))
  #expect(try volume.contains("bundle/disk.img"))
  #expect(try SafeFile.read(sentinel, limit: 8) == Data("keep".utf8))
  try BaseStageWorkspace.prune(stage, image: true, journal: outer)
  #expect(try !volume.contains("bundle/disk.img"))
  #expect(try volume.contains("journal.json"))
  #expect(try SafeFile.read(sentinel, limit: 8) == Data("keep".utf8))
  #expect(throws: (any Error).self) {
    try BaseStageWorkspace.prune(temporary.url, image: true, journal: outer)
  }
}

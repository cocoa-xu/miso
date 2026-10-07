import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func xcodeSelectionRequiresReadableRootOwnedLink() throws {
  var info = stat()
  info.st_mode = S_IFLNK | 0o755
  try XcodeApplication.validateSelectionMetadata(info)
  for mode: mode_t in [S_IFLNK | 0o700, S_IFLNK | 0o777, S_IFLNK | 0o644, S_IFREG | 0o755] {
    var invalid = info
    invalid.st_mode = mode
    #expect(throws: MisoError.self) { try XcodeApplication.validateSelectionMetadata(invalid) }
  }
  info.st_uid = 501
  #expect(throws: MisoError.self) { try XcodeApplication.validateSelectionMetadata(info) }
  info.st_uid = 0
  info.st_gid = 20
  #expect(throws: MisoError.self) { try XcodeApplication.validateSelectionMetadata(info) }
}

@Test func xcodeStagesPreserveBaseCompletionWithoutCompletingXcode() throws {
  let baseStages = ["base-static", "base-cleanup"]
  var manifest: [String: Any] = ["base_complete": true, "base_stages": baseStages]
  try BaseImageStage.advanceManifest(&manifest, operation: "xcode-application", layer: .xcode)
  #expect(manifest["base_complete"] as? Bool == true)
  #expect(manifest["base_stages"] as? [String] == baseStages)
  #expect(manifest["xcode_complete"] as? Bool == false)
  #expect(manifest["xcode_stages"] as? [String] == ["xcode-application"])
  #expect(throws: MisoError.self) {
    try BaseImageStage.advanceManifest(&manifest, operation: "xcode-application", layer: .xcode)
  }
  #expect(throws: MisoError.self) {
    try BaseImageStage.advanceManifest(&manifest, operation: "base-bootstrap", layer: .base)
  }
  for invalid: [String: Any] in [
    [:], ["base_complete": false], ["base_complete": true, "xcode_complete": true],
  ] {
    var value = invalid
    #expect(throws: MisoError.self) {
      try BaseImageStage.advanceManifest(&value, operation: "xcode-application", layer: .xcode)
    }
  }
}

@Test func androidReplacementRequiresFinalizedSourceAndInvalidatesCompletion() throws {
  let configuration = XcodeConfiguration()
  let stages = XcodeCompletion.requiredStages(configuration).sorted() + ["xcode-finalize"]
  let original: [String: Any] = [
    "base_complete": true, "construction_vm_started": false, "runtime_verified": false,
    "xcode_complete": true, "xcode_stages": stages,
    "xcode_configuration": try JSONSerialization.jsonObject(with: JSON.encode(configuration)),
  ]
  var manifest = original
  try BaseImageStage.advanceManifest(
    &manifest, operation: "xcode-android", layer: .xcode, reapply: true)
  try XcodeCompletion.requireStages(
    JSONSerialization.data(withJSONObject: manifest), configuration: configuration, finalized: false
  )
  #expect(
    manifest["xcode_configuration"] as? NSDictionary == original["xcode_configuration"]
      as? NSDictionary)
  #expect(throws: MisoError.self) {
    try BaseImageStage.advanceManifest(
      &manifest, operation: "xcode-android", layer: .xcode, reapply: true)
  }
  for operation in ["xcode-application", "xcode-packages", "xcode-finalize"] {
    var invalid = original
    #expect(throws: MisoError.self) {
      try BaseImageStage.advanceManifest(
        &invalid, operation: operation, layer: .xcode, reapply: true)
    }
  }
}

@Test func xcodeSelectionRejectsUnrelatedLinksAndRegularFiles() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let root = temporary.url
  let directory = "Applications/Xcode_27.0.app/Contents/Developer"
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
  let database = root.appendingPathComponent("private/var/db")
  try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
  let selection = database.appendingPathComponent("xcode_select_link")
  try FileManager.default.createSymbolicLink(
    atPath: selection.path, withDestinationPath: "/unrelated")
  let data = try GuestVolume(root)
  #expect(throws: MisoError.self) { try XcodeApplication.select("/" + directory, data: data) }
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: selection.path) == "/unrelated")
  try FileManager.default.removeItem(at: selection)
  try SafeFile.writeNew(Data("preserved".utf8), to: selection)
  #expect(throws: MisoError.self) { try XcodeApplication.select("/" + directory, data: data) }
  #expect(try SafeFile.read(selection, limit: 64) == Data("preserved".utf8))
  #expect(throws: MisoError.self) {
    try XcodeApplication.select("/Applications/../Library/test.app/Contents/Developer", data: data)
  }
}

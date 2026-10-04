import Foundation
import Testing
import Virtualization

@testable import MisoCore

@MainActor
private func exportFixture(_ directory: URL) throws -> URL {
  let source = directory.appendingPathComponent("source")
  try SafeFile.makeDirectory(source)
  let model = try #require(
    Data(
      base64Encoded:
        "YnBsaXN0MDDTAQIDBAQFXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxACowYHBxANEAAIDys9UlRYWgAAAAAAAAEBAAAAAAAAAAgAAAAAAAAAAAAAAAAAAABc"
    ))
  try SafeFile.writeNew(Data("disk fixture".utf8), to: source.appendingPathComponent("disk.img"))
  try SafeFile.writeNew(model, to: source.appendingPathComponent("hardware-model.bin"))
  try SafeFile.writeNew(
    VZMacMachineIdentifier().dataRepresentation,
    to: source.appendingPathComponent("machine-identifier.bin"))
  let auxiliary = try SafeFile.create(source.appendingPathComponent("aux.bin"))
  try auxiliary.truncate(atOffset: UInt64(AuxiliaryStorage.size))
  try auxiliary.close()
  let files = try ImageBundle.requiredFiles.sorted().map {
    try Artifacts.record(source.appendingPathComponent($0), relativeTo: source)
  }
  let manifest: [String: Any] = [
    "schema_version": 1, "target": ["version": "27.0.1", "build": "26A434"],
    "construction_vm_started": false, "minimum_cpus": 2,
    "minimum_memory_bytes": UInt64(4 << 30),
    "files": try JSONSerialization.jsonObject(with: JSON.encode(files)),
  ]
  try SafeFile.writeNew(
    JSONSerialization.data(withJSONObject: manifest),
    to: source.appendingPathComponent("manifest.json"))
  return source
}

@Test @MainActor func tartExportPreservesIdentityAndIsolatesTheSourceDisk() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let source = try exportFixture(temporary.url)
  let output = temporary.url.appendingPathComponent("export")
  let receipt = try TartBundle.export(source: source, output: output)
  let bundle = output.appendingPathComponent("vm")
  let config = try #require(
    JSONSerialization.jsonObject(
      with: SafeFile.read(bundle.appendingPathComponent("config.json"), limit: 4096))
      as? [String: Any])
  for (field, name) in [
    ("hardwareModel", "hardware-model.bin"), ("ecid", "machine-identifier.bin"),
  ] {
    let encoded = try #require(config[field] as? String)
    #expect(
      try Data(base64Encoded: encoded)
        == SafeFile.read(source.appendingPathComponent(name), limit: 4096))
  }
  #expect(
    try SafeFile.sha256(bundle.appendingPathComponent("nvram.bin"))
      == SafeFile.sha256(source.appendingPathComponent("aux.bin")))
  #expect(
    receipt.files.first { $0.path == "disk.img" }?.sha256
      == SafeFile.sha256(Data("disk fixture".utf8)))
  let disk = try FileHandle(forWritingTo: bundle.appendingPathComponent("disk.img"))
  try disk.write(contentsOf: Data("changed export".utf8))
  try disk.close()
  #expect(
    try SafeFile.read(source.appendingPathComponent("disk.img"), limit: 1024)
      == Data("disk fixture".utf8))
  #expect(throws: MisoError.self) { try TartBundle.export(source: source, output: output) }
}

@Test @MainActor func tartExportRejectsChangedInputsBeforeCreatingOutput() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let source = try exportFixture(temporary.url)
  let output = temporary.url.appendingPathComponent("export")
  try SafeFile.replace(Data("corrupt disk".utf8), at: source.appendingPathComponent("disk.img"))
  #expect(throws: MisoError.self) { try TartBundle.export(source: source, output: output) }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

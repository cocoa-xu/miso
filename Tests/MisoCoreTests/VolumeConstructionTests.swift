import Foundation
import Testing

@testable import MisoCore

@Test func xartObjectValidationAndRoleChange() throws {
  let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
  var block = Data(count: 4096)
  #expect(try XART.checksum(block) == Data(repeating: 255, count: 8))
  block.replaceSubrange(32..<36, with: Data("APSB".utf8))
  block.replaceSubrange(240..<256, with: id.bytes)
  block.replaceSubrange(0..<8, with: try XART.checksum(block))
  let changed = try #require(try XART.changed(block, volume: id))
  #expect(try changed.integer(at: 964, as: UInt16.self) == 0x100)
  #expect(try XART.checksum(changed) == changed.prefix(8))
  #expect(try XART.changed(block, volume: UUID()) == nil)
  #expect(throws: (any Error).self) { try XART.changed(changed, volume: id) }
  var damaged = block
  damaged[8] ^= 1
  #expect(throws: (any Error).self) { try XART.changed(damaged, volume: id) }
  block.put(UInt64(1), at: 216)
  block.replaceSubrange(0..<8, with: try XART.checksum(block))
  #expect(throws: (any Error).self) { try XART.changed(block, volume: id) }
}

@Test func nativeClonePreservesItsSource() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let source = directory.url.appendingPathComponent("source")
  let clone = directory.url.appendingPathComponent("clone")
  let original = Data(repeating: 3, count: 8192)
  try SafeFile.writeNew(original, to: source)
  try Artifacts.clone(source, to: clone)
  #expect(try SafeFile.sha256(source) == SafeFile.sha256(clone))
  let writable = try SafeFile.openRegular(clone, writable: true)
  try writable.write(contentsOf: Data([4]))
  try writable.close()
  #expect(try SafeFile.read(source, limit: 8192) == original)
  #expect(throws: (any Error).self) { try Artifacts.clone(source, to: clone) }
}

@Test func volumeLayoutGuardsAndRoleSets() throws {
  let layout = try DiskLayout(diskBytes: 40 << 30, sourceBytes: 12 << 30)
  try VolumeConstruction.validateLayout(layout)
  #expect(VolumeConstruction.kind(DiskLayout.iscType.uuidString) == .isc)
  #expect(VolumeConstruction.kind("Apple_APFS_Recovery") == .recovery)
  var state: [VolumeConstruction.Kind: APFSTopology.Container] = [:]
  for (index, kind) in VolumeConstruction.Kind.allCases.enumerated() {
    let device = "disk\(index + 20)"
    let roles = VolumeConstruction.expectedRoles[kind]!.sorted()
    let volumes = roles.enumerated().map { offset, role in
      APFSTopology.Volume(
        device: device + "s\(offset + 1)", identifier: UUID(), roles: [role], name: role,
        mountPoint: nil)
    }
    state[kind] = .init(
      device: device, identifier: UUID(), stores: [.init(device: "disk18s\(index + 1)")],
      volumes: volumes)
  }
  try VolumeConstruction.verifyRoles(state)
  state.removeValue(forKey: .isc)
  #expect(throws: (any Error).self) { try VolumeConstruction.verifyRoles(state) }
}

@Test func volumeGroupsRejectDuplicateRoles() throws {
  let container = UUID()
  let system = UUID()
  let data = UUID()
  let report = VolumeConstruction.Groups(containers: [
    .init(
      identifier: container,
      groups: [
        .init(
          identifier: data,
          volumes: [
            .init(role: "System", identifier: system), .init(role: "Data", identifier: data),
          ])
      ])
  ])
  try VolumeConstruction.verifyGroups(report, container: container, system: system, data: data)
  let duplicate = VolumeConstruction.Groups(containers: [
    .init(
      identifier: container,
      groups: [
        .init(
          identifier: data,
          volumes: [
            .init(role: "System", identifier: system), .init(role: "System", identifier: system),
          ])
      ])
  ])
  #expect(throws: (any Error).self) {
    try VolumeConstruction.verifyGroups(duplicate, container: container, system: system, data: data)
  }
}

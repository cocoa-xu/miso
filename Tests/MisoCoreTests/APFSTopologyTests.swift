import Foundation
import Testing

@testable import MisoCore

private let topologyAttachment = DiskImageAttachment(entities: [
  .init(device: "/dev/disk11", contentHint: "GUID_partition_scheme", mountPoint: nil),
  .init(device: "/dev/disk11s2", contentHint: "Apple_APFS", mountPoint: nil),
])

private func topologyContainer(store: String = "disk11s2") -> [String: Any] {
  [
    "ContainerReference": "disk12",
    "APFSContainerUUID": UUID().uuidString,
    "PhysicalStores": [["DeviceIdentifier": store]],
    "Volumes": [
      ["DeviceIdentifier": "disk12s1", "APFSVolumeUUID": UUID().uuidString, "Roles": ["System"]]
    ],
  ]
}

private func topologyInventory(_ containers: [[String: Any]]) throws -> Data {
  try PropertyListSerialization.data(
    fromPropertyList: ["Containers": containers], format: .xml, options: 0)
}

@Test func topologyDecodingIgnoresIncompleteForeignVolumes() throws {
  let own = topologyContainer()
  var foreign = topologyContainer(store: "disk21s2")
  foreign["Volumes"] = [["DeviceIdentifier": "disk22s1", "Roles": ["Data"]]]
  let data = try topologyInventory([foreign, own])
  #expect(throws: DecodingError.self) {
    try PropertyListDecoder().decode(APFSTopology.self, from: data)
  }
  let containers = try APFSTopology.owned(in: data, by: topologyAttachment)
  #expect(containers.count == 1)
  #expect(containers.first?.identifier.uuidString == own["APFSContainerUUID"] as? String)
  #expect(containers.first?.volumes.first?.device == "disk12s1")
}

@Test func topologyDecodingStillRejectsIncompleteOwnedVolumes() throws {
  var own = topologyContainer()
  own["Volumes"] = [["DeviceIdentifier": "disk12s1", "Roles": ["System"]]]
  #expect(throws: DecodingError.self) {
    try APFSTopology.owned(in: topologyInventory([own]), by: topologyAttachment)
  }
}

@Test func topologyDecodingStillRejectsMixedAndMalformedOwnedStores() throws {
  for other: Any in [["DeviceIdentifier": "disk21s2"], ["MissingDevice": true], "invalid"] {
    var own = topologyContainer()
    own["PhysicalStores"] = [["DeviceIdentifier": "disk11s2"], other]
    #expect(throws: (any Error).self) {
      try APFSTopology.owned(in: topologyInventory([own]), by: topologyAttachment)
    }
  }
}

@Test func topologyDecodingStillRejectsDuplicateOwnershipAndEscapingVolumes() throws {
  let own = topologyContainer()
  #expect(throws: MisoError.self) {
    try APFSTopology.owned(in: topologyInventory([own, own]), by: topologyAttachment)
  }
  var escaping = topologyContainer()
  escaping["Volumes"] = [
    ["DeviceIdentifier": "disk22s1", "APFSVolumeUUID": UUID().uuidString, "Roles": ["System"]]
  ]
  #expect(throws: MisoError.self) {
    try APFSTopology.owned(in: topologyInventory([escaping]), by: topologyAttachment)
  }
}

@Test func topologyDecodingMatchesExactOwnedDevices() throws {
  let containers: [[String: Any]] = [
    topologyContainer(store: "disk111s2"), topologyContainer(store: "disk11s20"),
    ["PhysicalStores": [["DeviceIdentifier": "disk21s2"]]],
    ["Volumes": [["Roles": ["Data"]]]],
  ]
  #expect(
    try APFSTopology.owned(in: topologyInventory(containers), by: topologyAttachment).isEmpty)
}

@Test func topologyDecodingRejectsMalformedEnvelope() throws {
  for envelope: Any in [["Containers": "invalid"], ["Other": []], ["Containers": [42]]] {
    let data = try PropertyListSerialization.data(
      fromPropertyList: envelope, format: .binary, options: 0)
    #expect(throws: MisoError.self) {
      try APFSTopology.owned(in: data, by: topologyAttachment)
    }
  }
}

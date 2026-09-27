import Foundation
import Testing

@testable import MisoCore

@Test func privateHostSupportRequiresAnExactTestedOSAndAPFSCombination() throws {
  func host(_ version: String, _ build: String, _ architecture: String = "arm64") -> HostInfo {
    HostInfo(
      productVersion: version, productBuild: build, architecture: architecture,
      physicalMemory: 24 << 30, capturedAt: Date())
  }
  for build in ["26A5425a", "26A428"] {
    #expect(
      try APFSPrivate.validateHost(host("27.0", build), apfsVersion: "3288.1.3") == "3288.1.3")
  }
  for value in [host("27.0.1", "26A434"), host("27.0", "26A999"), host("27.0", "26A428", "x86_64")]
  {
    #expect(throws: MisoError.self) { try APFSPrivate.validateHost(value, apfsVersion: "3288.1.3") }
  }
  for version in [nil, "3288.1.4", "3288.1.3.1"] {
    #expect(throws: MisoError.self) {
      try APFSPrivate.validateHost(host("27.0", "26A428"), apfsVersion: version)
    }
  }
}

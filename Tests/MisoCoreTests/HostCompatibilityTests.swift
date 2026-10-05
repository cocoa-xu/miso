import Foundation
import Testing

@testable import MisoCore

@Test func privateHostSupportDoesNotRejectUnlistedVersions() throws {
  func host(_ version: String, _ build: String, _ architecture: String = "arm64") -> HostInfo {
    HostInfo(
      productVersion: version, productBuild: build, architecture: architecture,
      physicalMemory: 24 << 30, capturedAt: Date())
  }
  for value in [host("27.0", "26A428"), host("27.0.1", "26A434"), host("28.0", "27A999")] {
    for version in [nil, "3288.1.3", "3288.1.4", "4000.1"] {
      #expect(try APFSPrivate.validateHost(value, apfsVersion: version) == (version ?? "unknown"))
    }
  }
  #expect(throws: MisoError.self) {
    try APFSPrivate.validateHost(host("27.0", "26A428", "x86_64"), apfsVersion: "3288.1.3")
  }
}

@Test func nativeLibraryFailuresIdentifyTheMissingCapabilityAndHost() throws {
  let host = HostInfo(
    productVersion: "28.0", productBuild: "27A999", architecture: "arm64",
    physicalMemory: 24 << 30, capturedAt: Date())
  let path = "/miso-missing-framework-\(UUID().uuidString)/APFS"
  do {
    _ = try NativeLibrary(path, host: host)
    Issue.record("Missing library was accepted")
  } catch {
    for expected in ["Cannot load", path, "28.0", "27A999", "arm64", "dlopen"] {
      #expect(error.localizedDescription.contains(expected))
    }
  }
  let library = try NativeLibrary("/usr/lib/libSystem.B.dylib", host: host)
  defer { withExtendedLifetime(library) {} }
  do {
    _ = try library.symbol(APFSPrivate.groupSymbol)
    Issue.record("Missing symbol was accepted")
  } catch {
    for expected in [
      "Missing required symbol", APFSPrivate.groupSymbol, library.path, "28.0", "27A999", "dlsym",
    ] {
      #expect(error.localizedDescription.contains(expected))
    }
  }
  _ = try library.symbol("getpid")
}

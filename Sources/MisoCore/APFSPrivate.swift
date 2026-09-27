import CoreFoundation
import Darwin
import Foundation

enum APFSPrivate {
  static func requireHost() throws -> String {
    let host = try HostInfo.current()
    let path = URL(fileURLWithPath: "/System/Library/Filesystems/apfs.fs/Contents/Info.plist")
    let info = try RestoreInspection.plist(SafeFile.read(path, limit: 1 << 20))
    return try validateHost(host, apfsVersion: info["CFBundleVersion"] as? String)
  }

  static func validateHost(_ host: HostInfo, apfsVersion: String?) throws -> String {
    guard host.architecture == "arm64", host.productVersion == "27.0",
      ["26A5425a", "26A428"].contains(host.productBuild), apfsVersion == "3288.1.3"
    else {
      throw MisoError.unsupported("private APFS operations on this host build")
    }
    return "3288.1.3"
  }

  static func group(_ session: DiskImageSession, container: UUID, system: UUID, data: UUID) throws {
    _ = try requireHost()
    let matches = try session.containers().filter { $0.identifier == container }
    guard matches.count == 1, let selected = matches.first else {
      throw MisoError.invalid("Volume-group container ownership mismatch")
    }
    var indices: [NSNumber] = []
    for (role, id) in [("System", system), ("Data", data)] {
      let volume = try selected.volume(role: role)
      guard volume.identifier == id, volume.mountPoint == nil,
        let index = UInt8(volume.device.dropFirst(selected.device.count + 1)), index > 0
      else {
        throw MisoError.invalid("Volume-group identity or mount state mismatch")
      }
      indices.append(NSNumber(value: index))
    }
    guard let framework = dlopen("/System/Library/PrivateFrameworks/APFS.framework/APFS", RTLD_NOW),
      let symbol = dlsym(framework, "APFSContainerVolumeGroupAdd")
    else { throw MisoError.unsupported("APFS volume-group API unavailable") }
    defer { dlclose(framework) }
    typealias AddGroup =
      @convention(c) (UnsafePointer<CChar>, CFArray, UnsafeMutableRawPointer) -> Int32
    let add = unsafeBitCast(symbol, to: AddGroup.self)
    var result = [UInt8](repeating: 0, count: 16)
    let status = result.withUnsafeMutableBytes { bytes in
      ("/dev/" + selected.device).withCString { add($0, indices as CFArray, bytes.baseAddress!) }
    }
    guard status == 0 else {
      throw MisoError.invalid("APFS volume-group creation failed (\(status))")
    }
  }
}

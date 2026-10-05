import CoreFoundation
import Darwin
import Foundation

enum APFSPrivate {
  static let frameworkPath = "/System/Library/PrivateFrameworks/APFS.framework/APFS"
  static let groupSymbol = "APFSContainerVolumeGroupAdd"

  static func requireHost() throws -> String {
    let host = try HostInfo.current()
    let path = URL(fileURLWithPath: "/System/Library/Filesystems/apfs.fs/Contents/Info.plist")
    let info = try? RestoreInspection.plist(SafeFile.read(path, limit: 1 << 20))
    let version = try validateHost(host, apfsVersion: info?["CFBundleVersion"] as? String)
    let library = try NativeLibrary(frameworkPath, host: host)
    defer { withExtendedLifetime(library) {} }
    _ = try library.symbol(groupSymbol)
    return version
  }

  static func validateHost(_ host: HostInfo, apfsVersion: String?) throws -> String {
    guard host.architecture == "arm64" else {
      throw MisoError.unsupported(
        "Offline image construction requires arm64; host is \(host.architecture) "
          + "on macOS \(host.productVersion) (\(host.productBuild))")
    }
    return apfsVersion ?? "unknown"
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
    let library = try NativeLibrary(frameworkPath)
    defer { withExtendedLifetime(library) {} }
    let symbol = try library.symbol(groupSymbol)
    typealias AddGroup =
      @convention(c) (UnsafePointer<CChar>, CFArray, UnsafeMutableRawPointer) -> Int32
    let add = unsafeBitCast(symbol, to: AddGroup.self)
    var result = [UInt8](repeating: 0, count: 16)
    let status = result.withUnsafeMutableBytes { bytes in
      ("/dev/" + selected.device).withCString { add($0, indices as CFArray, bytes.baseAddress!) }
    }
    guard status == 0 else {
      throw MisoError.invalid(
        "\(groupSymbol) in \(frameworkPath) returned \(status) for /dev/\(selected.device) "
          + "on macOS \(library.host.productVersion) (\(library.host.productBuild))")
    }
  }
}

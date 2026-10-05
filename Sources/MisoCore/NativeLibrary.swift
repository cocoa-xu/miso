import Darwin
import Foundation

final class NativeLibrary {
  let path: String
  let host: HostInfo
  private let handle: UnsafeMutableRawPointer

  init(_ path: String, host: HostInfo? = nil) throws {
    self.path = path
    self.host = try host ?? HostInfo.current()
    _ = dlerror()
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
      let detail = dlerror().map { String(cString: $0) } ?? "No loader diagnostic"
      throw MisoError.unsupported(
        "Cannot load \(path) on macOS \(self.host.productVersion) "
          + "(\(self.host.productBuild), \(self.host.architecture)): \(detail)")
    }
    self.handle = handle
  }

  deinit { dlclose(handle) }

  func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
    _ = dlerror()
    guard let symbol = dlsym(handle, name) else {
      let detail = dlerror().map { String(cString: $0) } ?? "No loader diagnostic"
      throw MisoError.unsupported(
        "Missing required symbol \(name) in \(path) on macOS \(host.productVersion) "
          + "(\(host.productBuild), \(host.architecture)): \(detail)")
    }
    return symbol
  }
}

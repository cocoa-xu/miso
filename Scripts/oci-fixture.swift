import Foundation
import Security
import Virtualization

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
let configuration: [String: Any] = [
  "version": 1, "os": "darwin", "arch": "arm64", "diskFormat": "raw",
  "cpuCountMin": 2, "cpuCount": 2, "memorySizeMin": 4 << 30, "memorySize": 4 << 30,
  "hardwareModel":
    "YnBsaXN0MDDTAQIDBAQFXxAZRGF0YVJlcHJlc2VudGF0aW9uVmVyc2lvbl8QD1BsYXRmb3JtVmVyc2lvbl8QEk1pbmltdW1TdXBwb3J0ZWRPUxACowYHBxANEAAIDys9UlRYWgAAAAAAAAEBAAAAAAAAAAgAAAAAAAAAAAAAAAAAAABc",
  "ecid": VZMacMachineIdentifier().dataRepresentation.base64EncodedString(),
  "macAddress": VZMACAddress.randomLocallyAdministered().string,
  "display": ["width": 1024, "height": 768],
]
try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
  .write(to: directory.appendingPathComponent("config.json"), options: .withoutOverwriting)
try Data(repeating: 0, count: 1 << 20)
  .write(to: directory.appendingPathComponent("nvram.bin"), options: .withoutOverwriting)
let url = directory.appendingPathComponent("disk.img")
try Data().write(to: url, options: .withoutOverwriting)
let disk = try FileHandle(forWritingTo: url)
defer { try? disk.close() }
try disk.truncate(atOffset: 2 << 30)
var bytes = Data(count: 16 << 20)
let result = bytes.withUnsafeMutableBytes {
  SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
}
guard result == errSecSuccess else { fatalError("Cannot generate transport fixture") }
try disk.write(contentsOf: bytes)
try disk.seek(toOffset: (2 << 30) - UInt64(bytes.count))
try disk.write(contentsOf: bytes)

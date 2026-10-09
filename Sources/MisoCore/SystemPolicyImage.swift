import Darwin
import Foundation
import Virtualization

public enum SystemPolicyImage {
  public struct Receipt: Encodable {
    let image = "vm"
    let policy: OfflineSystemPolicy.Receipt
    let sourceUnchanged = true
    let vmStarted = false
    let runtimeVerified = false
  }

  @MainActor public static func configure(
    source: URL, output: URL, policy: SystemPolicy, username: String = "admin",
    cancellation: CancellationToken? = nil
  ) throws -> Receipt {
    guard geteuid() == 0 else {
      throw MisoError.invalid("Offline system configuration requires administrator privileges")
    }
    try policy.validate()
    guard !policy.isEmpty else { throw MisoError.invalid("Empty system policy") }
    let names: Set<String> = ["disk.img", "nvram.bin", "config.json"]
    let before = try ImageBundle.snapshot(source, files: names)
    let config = try JSON.read(
      TartBundle.Configuration.self, from: source.appendingPathComponent("config.json"),
      limit: 1 << 20)
    guard config.version == 1, config.os == "darwin", config.arch == "arm64",
      config.diskFormat == "raw",
      VZMacHardwareModel(dataRepresentation: config.hardwareModel) != nil,
      VZMacMachineIdentifier(dataRepresentation: config.ecid) != nil
    else { throw MisoError.invalid("Invalid offline VM image configuration") }
    let journal = try ExecutionJournal(
      output: output, operation: "configure-system-image", cancellation: cancellation)
    return try journal.perform {
      let origin = try DiskImageSession(
        image: source.appendingPathComponent("disk.img"), readOnly: true, journal: journal)
      try origin.requireDetached()
      let image = output.appendingPathComponent("vm")
      try SafeFile.makeDirectory(image)
      for name in names.sorted() {
        try Artifacts.clone(
          source.appendingPathComponent(name), to: image.appendingPathComponent(name))
      }
      var profile = XcodeBuildProfile()
      profile.system = policy
      profile.cleanup = false
      profile.sparsify = false
      let details = try ImageOptimization.apply(
        bundle: image, username: username, compress: false, profile: profile, journal: journal)
      guard let receipt = details.systemPolicy else {
        throw MisoError.invalid("System policy receipt is missing")
      }
      try origin.requireDetached()
      guard try ImageBundle.snapshot(source, files: names) == before else {
        throw MisoError.invalid("Source image changed during offline configuration")
      }
      return Receipt(policy: receipt)
    }
  }
}

import Foundation
import Virtualization

@MainActor
public enum VirtualHardware {
  public struct IdentityReceipt: Encodable, Sendable {
    public let host: HostInfo
    public let release: MacOSRelease
    public let minimumCPUCount: Int
    public let minimumMemoryBytes: UInt64
    public let files: [ImageBundle.FileRecord]
    public let virtualMachineCreated = false
    public let installerInvoked = false
    public let vmStarted = false
  }

  public static func createIdentity(ipsw: URL, output: URL) async throws -> IdentityReceipt {
    let inspected = try RestoreInspection.inspect(ipsw, verifyDigest: true)
    let restore = try await VZMacOSRestoreImage.image(from: ipsw)
    let version = restore.operatingSystemVersion
    let actualVersion = try MacOSVersion(
      "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    guard actualVersion == (try MacOSVersion(inspected.profile.release.version)),
      restore.buildVersion == inspected.profile.release.build,
      restore.isSupported, let requirements = restore.mostFeaturefulSupportedConfiguration,
      requirements.hardwareModel.isSupported
    else { throw MisoError.unsupported("restore image or virtual hardware on this host") }
    try SafeFile.makeDirectory(output)
    let model = requirements.hardwareModel
    let identifier = VZMacMachineIdentifier()
    _ = try VZMacAuxiliaryStorage(
      creatingStorageAt: output.appendingPathComponent("aux-empty.bin"), hardwareModel: model)
    try SafeFile.writeNew(
      model.dataRepresentation, to: output.appendingPathComponent("hardware-model.bin"))
    try SafeFile.writeNew(
      identifier.dataRepresentation, to: output.appendingPathComponent("machine-identifier.bin"))
    let files = try ["aux-empty.bin", "hardware-model.bin", "machine-identifier.bin"].map { name in
      let url = output.appendingPathComponent(name)
      let handle = try SafeFile.openRegular(url)
      defer { try? handle.close() }
      return ImageBundle.FileRecord(
        path: name, bytes: try SafeFile.size(handle), sha256: try SafeFile.sha256(handle))
    }
    let receipt = IdentityReceipt(
      host: try HostInfo.current(), release: inspected.profile.release,
      minimumCPUCount: requirements.minimumSupportedCPUCount,
      minimumMemoryBytes: requirements.minimumSupportedMemorySize, files: files)
    try SafeFile.writeNew(JSON.encode(receipt), to: output.appendingPathComponent("identity.json"))
    return receipt
  }

  public struct ValidationReceipt: Encodable, Sendable {
    public let host: HostInfo
    public let cpuCount: Int
    public let memoryBytes: UInt64
    public let auxiliarySHA256: String
    public let configurationValidationPassed = true
    public let invalidCPUCountRejected = true
    public let diskReadOnly = true
    public let networkInterfaces = 0
    public let auxiliaryUnchanged = true
    public let virtualMachineCreated = false
    public let installerInvoked = false
    public let vmStarted = false
    public let bootabilityProven = false
  }

  public static func validateBundle(_ bundle: URL, cpuCount: Int = 4, memoryBytes: UInt64 = 4 << 30)
    throws -> ValidationReceipt
  {
    guard cpuCount > 0, memoryBytes > 0 else {
      throw MisoError.invalid("CPU count and memory must be positive")
    }
    let auxiliaryURL = bundle.appendingPathComponent("aux.bin")
    let before = try SafeFile.read(auxiliaryURL, limit: AuxiliaryStorage.size)
    guard before.count == AuxiliaryStorage.size else {
      throw MisoError.invalid("Unexpected auxiliary storage size")
    }
    let modelData = try SafeFile.read(
      bundle.appendingPathComponent("hardware-model.bin"), limit: 1 << 20)
    let machineData = try SafeFile.read(
      bundle.appendingPathComponent("machine-identifier.bin"), limit: 1 << 20)
    guard let model = VZMacHardwareModel(dataRepresentation: modelData), model.isSupported,
      let identifier = VZMacMachineIdentifier(dataRepresentation: machineData)
    else {
      throw MisoError.unsupported("bundle hardware model or machine identifier")
    }
    let diskURL = bundle.appendingPathComponent("disk.img")
    let disk = try SafeFile.openRegular(diskURL)
    defer { try? disk.close() }
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = model
    platform.machineIdentifier = identifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliaryURL)
    let configuration = VZVirtualMachineConfiguration()
    configuration.platform = platform
    configuration.bootLoader = VZMacOSBootLoader()
    configuration.cpuCount = cpuCount
    configuration.memorySize = memoryBytes
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [
      VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 80)
    ]
    configuration.graphicsDevices = [graphics]
    configuration.storageDevices = [
      VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: true))
    ]
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    configuration.keyboards = [VZUSBKeyboardConfiguration()]
    configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    try configuration.validate()
    configuration.cpuCount = 0
    var invalidCPUCountRejected = false
    do { try configuration.validate() } catch { invalidCPUCountRejected = true }
    guard invalidCPUCountRejected else {
      throw MisoError.invalid("Configuration negative control was accepted")
    }
    guard before == (try SafeFile.read(auxiliaryURL, limit: AuxiliaryStorage.size)) else {
      throw MisoError.invalid("Auxiliary storage changed during configuration validation")
    }
    return ValidationReceipt(
      host: try HostInfo.current(), cpuCount: cpuCount, memoryBytes: memoryBytes,
      auxiliarySHA256: SafeFile.sha256(before))
  }
}

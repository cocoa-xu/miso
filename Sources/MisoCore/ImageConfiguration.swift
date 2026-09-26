import CMiso
import Foundation
import Security

public struct ImageConfiguration: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var username = "admin"
  public var password = "admin"
  public var fullName = "admin"
  public var timeZone = "GMT"
  public var automaticLogin = true
  public var filevault = false
  public var installRosetta = false
  public var includeLinuxTranslation = false
  public var remoteLogin = true
  public var screenSharing = true
  public var vncPassword = "admin"
  public var passwordlessSudo = true
  public var gatekeeperEnabled = false
  public var disableSleep = true
  public var desktopDefaults = true

  public init() {}

  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion = "schema_version"
    case username, password
    case fullName = "full_name"
    case timeZone = "time_zone"
    case automaticLogin = "automatic_login"
    case filevault
    case installRosetta = "install_rosetta"
    case includeLinuxTranslation = "include_linux_translation"
    case remoteLogin = "remote_login"
    case screenSharing = "screen_sharing"
    case vncPassword = "vnc_password"
    case passwordlessSudo = "passwordless_sudo"
    case gatekeeperEnabled = "gatekeeper_enabled"
    case disableSleep = "disable_sleep"
    case desktopDefaults = "desktop_defaults"
  }

  public static func read(_ url: URL) throws -> Self {
    let data = try SafeFile.read(url, limit: 1 << 20)
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(dictionary.keys) == Set(CodingKeys.allCases.map(\.rawValue))
    else {
      throw MisoError.invalid("Configuration must contain exactly the schema's keys")
    }
    let configuration = try JSONDecoder().decode(Self.self, from: data)
    try configuration.validate()
    return configuration
  }

  public func validate() throws {
    guard schemaVersion == 1 else { throw MisoError.unsupported("configuration schema") }
    guard username.range(of: #"\A[a-z][a-z0-9_-]{0,30}\z"#, options: .regularExpression) != nil,
      !["root", "daemon", "nobody", "guest"].contains(username)
    else {
      throw MisoError.invalid("Invalid account name")
    }
    for value in [password, fullName] {
      guard !value.isEmpty, value.utf8.count <= 512, !value.contains("\0") else {
        throw MisoError.invalid("Account fields must contain 1...512 UTF-8 bytes without NUL")
      }
    }
    guard !filevault else { throw MisoError.unsupported("offline FileVault provisioning") }
    guard (1...8).contains(vncPassword.utf8.count),
      vncPassword.utf8.allSatisfy({ (32...126).contains($0) })
    else {
      throw MisoError.invalid("VNC password must contain 1...8 printable ASCII bytes")
    }
    guard timeZone.range(of: #"\A[A-Za-z0-9_+/-]+\z"#, options: .regularExpression) != nil,
      (try? SafeFile.relativePath(timeZone)) != nil
    else {
      throw MisoError.invalid("Invalid time zone path")
    }
  }

  public func shadowHash() throws -> Data {
    try validate()
    var salt = Data(count: 32)
    let status = salt.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw MisoError.invalid("Secure randomness unavailable") }
    let entropy = try Self.derivePassword(password, salt: salt)
    return try PropertyListSerialization.data(
      fromPropertyList: [
        "SALTED-SHA512-PBKDF2": ["entropy": entropy, "salt": salt, "iterations": 200_000]
      ], format: .binary, options: 0)
  }

  static func derivePassword(_ password: String, salt: Data) throws -> Data {
    guard salt.count == 32 else { throw MisoError.invalid("Password salt must contain 32 bytes") }
    var entropy = Data(count: 128)
    let passwordBytes = Array(password.utf8)
    let status = entropy.withUnsafeMutableBytes { destination in
      salt.withUnsafeBytes { saltBytes in
        passwordBytes.withUnsafeBytes { passwordBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.bindMemory(to: Int8.self).baseAddress, passwordBytes.count,
            saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 200_000,
            destination.bindMemory(to: UInt8.self).baseAddress, destination.count)
        }
      }
    }
    guard status == 0 else { throw MisoError.invalid("Password derivation failed") }
    return entropy
  }
}

import Darwin
import Foundation
import Security

enum AppleCode {
  enum Scope { case full, executable }

  private static func flags(_ url: URL, scope: Scope) throws -> SecCSFlags {
    var value = kSecCSStrictValidate | kSecCSCheckAllArchitectures
    if scope == .executable {
      guard try FileMetadata.inspect(url).st_mode & S_IFMT == S_IFREG else {
        throw MisoError.invalid("Expected a regular executable for code-page validation")
      }
      value |= kSecCSDoNotValidateResources
    }
    return SecCSFlags(rawValue: value)
  }

  static func validateLocalTool(_ url: URL, scope: Scope = .full) throws {
    var code: SecStaticCode?
    var information: CFDictionary?
    let flags = try flags(url, scope: scope)
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess,
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let info = information as? [String: Any],
      let signatureFlags = info[kSecCodeInfoFlags as String] as? UInt32,
      signatureFlags & SecCodeSignatureFlags.adhoc.rawValue != 0,
      (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]).isEmpty
    else { throw MisoError.invalid("Expected a valid local tool signature without entitlements") }
  }

  static func validate(_ url: URL, scope: Scope = .full) throws {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw MisoError.invalid("Cannot inspect Apple code signature") }
    let flags = try flags(url, scope: scope)
    let status = SecStaticCodeCheckValidity(code, flags, requirement)
    guard status == errSecSuccess else {
      throw MisoError.invalid("Apple code signature rejected (\(status))")
    }
  }
}

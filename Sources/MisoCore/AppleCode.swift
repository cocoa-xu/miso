import Foundation
import Security

enum AppleCode {
  static func validate(_ url: URL) throws {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw MisoError.invalid("Cannot inspect Apple code signature") }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    let status = SecStaticCodeCheckValidity(code, flags, requirement)
    guard status == errSecSuccess else {
      throw MisoError.invalid("Apple code signature rejected (\(status))")
    }
  }
}

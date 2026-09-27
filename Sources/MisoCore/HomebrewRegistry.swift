import Foundation

enum HomebrewRegistry {
  static func repository(_ name: String) throws -> String {
    try PackageRequest(name: name).validate()
    let path = name.replacingOccurrences(of: "@", with: "/")
      .replacingOccurrences(of: "+", with: "x")
    guard
      path.range(
        of: #"\A[a-z0-9][a-z0-9._-]{0,100}(/[a-z0-9][a-z0-9._-]{0,100})?\z"#,
        options: .regularExpression) != nil
    else { throw MisoError.invalid("Invalid Homebrew registry repository") }
    return "https://ghcr.io/v2/homebrew/core/" + path
  }

  static func blob(name: String, sha256: String) throws -> URL {
    try SafeFile.validateSHA256(sha256)
    return URL(string: try repository(name) + "/blobs/sha256:" + sha256)!
  }

  static func index(_ formula: HomebrewResolution.Formula) throws -> URL {
    guard formula.revision >= 0, formula.bottle.rebuild >= 0 else {
      throw MisoError.invalid("Invalid Homebrew bottle revision or rebuild")
    }
    let rebuild = formula.bottle.rebuild == 0 ? "" : "-\(formula.bottle.rebuild)"
    let tag = formula.kegVersion + rebuild
    guard
      tag.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\z"#, options: .regularExpression)
        != nil
    else { throw MisoError.invalid("Invalid Homebrew OCI tag") }
    return URL(string: try repository(formula.name) + "/manifests/" + tag)!
  }

  static func permits(_ url: URL, index: Bool = false) -> Bool {
    let suffix =
      index
      ? #"/manifests/[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\z"#
      : #"/blobs/sha256:[a-f0-9]{64}\z"#
    return url.absoluteString.range(
      of:
        #"\Ahttps://ghcr\.io/v2/homebrew/core/[a-z0-9][a-z0-9._-]{0,100}(/[a-z0-9][a-z0-9._-]{0,100})?"#
        + suffix, options: .regularExpression) != nil
  }
}

import Foundation

struct HomebrewRubyVersion {
  let package: String
  let runtime: String

  init(_ value: String) throws {
    guard value.utf8.count <= 64,
      value.range(
        of: #"\A(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){2}(_[1-9][0-9]*)?\z"#,
        options: .regularExpression) != nil
    else { throw MisoError.invalid("Invalid portable Ruby version") }
    let upstream = String(value.split(separator: "_")[0])
    _ = try StableVersion(upstream)
    package = value
    runtime = upstream
  }
}

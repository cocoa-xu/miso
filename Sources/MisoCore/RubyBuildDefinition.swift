import Foundation

struct RubyBuildDefinition {
  struct Source: Codable, Equatable {
    let name: String
    let url: URL
    let sha256: String
  }

  let ruby: Source
  let openssl: Source
  let minimumOpenSSL: StableVersion
  let maximumOpenSSLMajor: UInt32

  init(_ data: Data, version: String) throws {
    _ = try StableVersion(version)
    guard version.split(separator: ".").count == 3, data.count <= 16_384,
      let text = String(data: data, encoding: .utf8)
    else { throw MisoError.invalid("Invalid Ruby build definition") }
    let lines = text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    guard lines.count == 2 else {
      throw MisoError.unsupported("Ruby definition requires unsupported build steps")
    }
    let package =
      #"\Ainstall_package "([a-z0-9.-]+)" "(https://[A-Za-z0-9:./_-]+)#([0-9a-f]{64})" "#
    let ssl = try Self.fields(
      lines[0],
      pattern: package + #"openssl --if needs_openssl:([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\.x\.x\z"#)
    let main = try Self.fields(
      lines[1], pattern: package + #"(?:warn_eol )?enable_shared standard\z"#)
    guard main[0] == "ruby-" + version,
      ssl[0].range(of: #"\Aopenssl-[0-9]+\.[0-9]+\.[0-9]+[a-z]?\z"#, options: .regularExpression)
        != nil,
      let rubyURL = URL(string: main[1]), let sslURL = URL(string: ssl[1]),
      let major = UInt32(ssl[4])
    else { throw MisoError.invalid("Ruby definition package identity mismatch") }
    let series = version.split(separator: ".").prefix(2).joined(separator: ".")
    guard
      rubyURL.absoluteString
        == "https://cache.ruby-lang.org/pub/ruby/\(series)/ruby-\(version).tar.gz"
    else { throw MisoError.invalid("Unexpected Ruby source URL") }
    let sslVersion = String(ssl[0].dropFirst("openssl-".count))
    let githubURL: URL
    if sslURL.absoluteString == "https://www.openssl.org/source/\(ssl[0]).tar.gz" {
      let tag =
        sslVersion.hasPrefix("1.")
        ? "OpenSSL_" + sslVersion.replacingOccurrences(of: ".", with: "_") : ssl[0]
      githubURL = URL(
        string: "https://github.com/openssl/openssl/releases/download/\(tag)/\(ssl[0]).tar.gz")!
    } else {
      guard
        sslURL.absoluteString
          == "https://github.com/openssl/openssl/releases/download/\(ssl[0])/\(ssl[0]).tar.gz"
      else { throw MisoError.invalid("Unexpected OpenSSL source URL") }
      githubURL = sslURL
    }
    minimumOpenSSL = try StableVersion(ssl[3])
    guard major >= minimumOpenSSL.components[0] else {
      throw MisoError.invalid("Invalid Ruby OpenSSL range")
    }
    maximumOpenSSLMajor = major
    ruby = Source(name: main[0] + ".tar.gz", url: rubyURL, sha256: main[2])
    openssl = Source(name: ssl[0] + ".tar.gz", url: githubURL, sha256: ssl[2])
  }

  func acceptsOpenSSL(_ version: String) throws -> Bool {
    let value = try StableVersion(version)
    return value >= minimumOpenSSL && value.components[0] <= maximumOpenSSLMajor
  }

  static func versions(_ names: [String], requested: String?) throws -> [String] {
    let stable = try names.filter {
      $0.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil
    }.map { ($0, try StableVersion($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    guard !stable.isEmpty, Set(stable).count == stable.count else {
      throw MisoError.invalid("Empty or duplicate Ruby definition catalog")
    }
    if let requested {
      _ = try StableVersion(requested)
      guard stable.contains(requested) else {
        throw MisoError.unsupported("Requested Ruby is absent from the selected ruby-build bottle")
      }
      return [requested]
    }
    return stable
  }

  private static func fields(_ line: String, pattern: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    else {
      throw MisoError.unsupported("Unsupported Ruby build definition syntax")
    }
    return (1..<match.numberOfRanges).map { String(line[Range(match.range(at: $0), in: line)!]) }
  }
}

import Foundation

public enum BaseCAInputs {
  public struct Plan: Codable {
    let schemaVersion: Int
    let target: MacOSRelease
    let snapshot: ImageBundle.FileRecord
    let classification: ImageBundle.FileRecord
    let pythonFormula: String
    let pythonExecutable: String

    func validate() throws {
      _ = try RestoreProfile.select(target)
      try PackageRequest(name: pythonFormula).validate()
      guard schemaVersion == 1, pythonFormula.hasPrefix("python@"),
        pythonExecutable.range(of: #"\Apython3\.[0-9]+\z"#, options: .regularExpression) != nil,
        snapshot.path != classification.path
      else { throw MisoError.invalid("Invalid CA plan") }
      for file in [snapshot, classification] {
        _ = try SafeFile.relativePath(file.path)
        try SafeFile.validateSHA256(file.sha256)
        guard (1...(16 << 20)).contains(file.bytes) else {
          throw MisoError.invalid("Invalid CA input size")
        }
      }
    }
  }

  struct Target: Decodable {
    let version: String
    let build: String
    enum CodingKeys: String, CodingKey {
      case version = "product_version"
      case build = "product_build"
    }
    var release: MacOSRelease { .init(version: version, build: build) }
  }

  struct Snapshot: Decodable {
    let target: Target
    let files: [ImageBundle.FileRecord]
  }

  struct Classification: Decodable {
    struct Entry: Decodable {
      let sha256: String
      let included: Bool?
      let excluded: String?
      let includedVia: String?
      enum CodingKeys: String, CodingKey {
        case sha256, included, excluded
        case includedVia = "included_via"
      }
      var eligible: Bool {
        included == true
          || ["expired or invalid at classification time", "not SSL server CA"].contains(
            excluded ?? "")
      }
      var path: String {
        "System/Library/Security/Certificates.bundle/Contents/Resources/Anchors/" + sha256 + ".cer"
      }
    }
    let target: Target
    let snapshotSHA256: String
    let selectedCount: Int
    let entries: [Entry]
    enum CodingKeys: String, CodingKey {
      case target, entries
      case snapshotSHA256 = "snapshot_sha256"
      case selectedCount = "selected_count"
    }
  }

  struct Verified {
    let plan: Plan
    let snapshot: Snapshot
    let classification: Classification
  }

  static func load(plan url: URL, inputs: URL, cancellation: CancellationToken?) throws -> Verified
  {
    let plan = try JSON.read(Plan.self, from: url)
    try plan.validate()
    let snapshot = try JSON.read(
      Snapshot.self,
      from: Artifacts.resolve(plan.snapshot, under: inputs, cancellation: cancellation))
    let classification = try JSON.read(
      Classification.self,
      from: Artifacts.resolve(plan.classification, under: inputs, cancellation: cancellation))
    guard snapshot.target.release == plan.target, classification.target.release == plan.target,
      classification.snapshotSHA256 == plan.snapshot.sha256,
      (1...2000).contains(snapshot.files.count),
      Set(snapshot.files.map(\.path)).count == snapshot.files.count,
      (1...1000).contains(classification.entries.count),
      Set(classification.entries.map(\.sha256)).count == classification.entries.count,
      classification.entries.filter({ $0.included == true }).count == classification.selectedCount,
      classification.selectedCount > 0
    else { throw MisoError.invalid("CA provenance or inventory differs") }
    for record in snapshot.files {
      _ = try SafeFile.relativePath(record.path)
      try SafeFile.validateSHA256(record.sha256)
      guard record.path.hasPrefix("System/Library/") || record.path == "private/etc/ssl/cert.pem",
        record.bytes > 0, record.bytes <= 16 << 20
      else { throw MisoError.invalid("Unsupported trust snapshot path") }
    }
    for entry in classification.entries {
      try SafeFile.validateSHA256(entry.sha256.lowercased())
      guard entry.sha256 == entry.sha256.uppercased(),
        !(entry.included == true && entry.excluded != nil),
        entry.includedVia == nil || entry.included == true,
        snapshot.files.contains(where: {
          $0.path == entry.path && $0.sha256 == entry.sha256.lowercased()
        })
      else {
        throw MisoError.invalid("CA classification entry lacks a bound target certificate")
      }
    }
    return Verified(plan: plan, snapshot: snapshot, classification: classification)
  }

  public static func verify(plan url: URL, inputs: URL, cancellation: CancellationToken? = nil)
    throws -> Plan
  {
    try load(plan: url, inputs: inputs, cancellation: cancellation).plan
  }
}

enum CertificatePEM {
  static func encode(_ data: Data) -> String {
    let encoded = Array(data.base64EncodedString().utf8)
    let lines = stride(from: 0, to: encoded.count, by: 64).map {
      String(decoding: encoded[$0..<min($0 + 64, encoded.count)], as: UTF8.self)
    }
    return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n")
      + "\n-----END CERTIFICATE-----\n"
  }

  static func decode(_ data: Data) throws -> [Data] {
    guard data.count <= 16 << 20, let text = String(data: data, encoding: .utf8) else {
      throw MisoError.invalid("Invalid PEM encoding or size")
    }
    let pattern = try NSRegularExpression(
      pattern: #"-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n]+)\s*-----END CERTIFICATE-----"#)
    let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard (1...2000).contains(matches.count),
      text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == matches.count + 1,
      text.components(separatedBy: "-----END CERTIFICATE-----").count == matches.count + 1
    else { throw MisoError.invalid("Malformed PEM certificate blocks") }
    return try matches.map {
      guard let range = Range($0.range(at: 1), in: text),
        let der = Data(base64Encoded: String(text[range].filter { !$0.isWhitespace })),
        !der.isEmpty, der.count <= 64 << 10
      else { throw MisoError.invalid("Invalid certificate base64") }
      return der
    }
  }
}

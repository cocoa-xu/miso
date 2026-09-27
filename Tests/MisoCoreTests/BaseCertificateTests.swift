import Foundation
import Testing

@testable import MisoCore

@Test func certificatePEMEncodingIsCanonicalAndRejectsMalformedBlocks() throws {
  let first = Data((0..<128).map(UInt8.init))
  let second = Data([0, 255, 1, 254])
  let encoded = CertificatePEM.encode(first) + "\n" + CertificatePEM.encode(second)
  #expect(try CertificatePEM.decode(Data(encoded.utf8)) == [first, second])
  #expect(
    encoded.split(separator: "\n").filter { !$0.hasPrefix("-----") }.allSatisfy { $0.count <= 64 })
  for invalid in [
    "", "-----BEGIN CERTIFICATE-----\n!invalid!\n-----END CERTIFICATE-----",
    encoded + "-----BEGIN CERTIFICATE-----\n",
    encoded.replacingOccurrences(of: "END CERTIFICATE", with: "END PRIVATE KEY"),
  ] {
    #expect(throws: (any Error).self) { try CertificatePEM.decode(Data(invalid.utf8)) }
  }
}

@Test func certificatePlansBindClassificationSnapshotAndTarget() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let fingerprint = String(repeating: "A", count: 64)
  let target = ["product_version": "26.6.2", "product_build": "25G83"]
  let snapshot = temporary.url.appendingPathComponent("snapshot.json")
  try SafeFile.writeNew(
    JSONSerialization.data(withJSONObject: [
      "target": target,
      "files": [
        [
          "path": "System/Library/Security/Certificates.bundle/Contents/Resources/Anchors/"
            + fingerprint + ".cer",
          "bytes": 100, "sha256": fingerprint.lowercased(),
        ]
      ],
    ]), to: snapshot)
  let snapshotRecord = try Artifacts.record(snapshot, relativeTo: temporary.url)
  let classification = temporary.url.appendingPathComponent("classification.json")
  try SafeFile.writeNew(
    JSONSerialization.data(withJSONObject: [
      "target": target,
      "snapshot_sha256": snapshotRecord.sha256, "selected_count": 1,
      "entries": [["sha256": fingerprint, "included": true]],
    ]), to: classification)
  let plan = BaseCAInputs.Plan(
    schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"),
    snapshot: snapshotRecord,
    classification: try Artifacts.record(classification, relativeTo: temporary.url),
    pythonFormula: "python@3.14", pythonExecutable: "python3.14")
  let planURL = temporary.url.appendingPathComponent("plan.json")
  try SafeFile.writeNew(JSON.encode(plan), to: planURL)
  #expect(try BaseCAInputs.verify(plan: planURL, inputs: temporary.url).target == plan.target)
  try Data("changed".utf8).write(to: snapshot)
  #expect(throws: (any Error).self) {
    try BaseCAInputs.verify(plan: planURL, inputs: temporary.url)
  }
}

@Test func certificateEligibilityDoesNotRestoreExplicitPolicyExclusions() {
  let fingerprint = String(repeating: "A", count: 64)
  func entry(_ included: Bool?, _ excluded: String?) -> BaseCAInputs.Classification.Entry {
    .init(sha256: fingerprint, included: included, excluded: excluded, includedVia: nil)
  }
  #expect(entry(true, nil).eligible)
  #expect(entry(nil, "expired or invalid at classification time").eligible)
  #expect(entry(false, "not SSL server CA").eligible)
  #expect(!entry(false, "explicitly distrusted").eligible)
  #expect(!entry(nil, "policy-constrained anchor").eligible)
}

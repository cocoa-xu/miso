import Darwin
import Foundation
import Security

public enum BaseCertificates {
  private static let stage = "opt/homebrew/var/miso-root-certificates"
  static let destination = "opt/homebrew/etc/ca-certificates/cert.pem"

  public struct Details: Codable {
    let plan: BaseCAInputs.Plan
    let planSHA256: String
    let certificateFingerprints: [String]
    let systemRootCount: Int
    let bundle: ImageBundle.FileRecord
    let detachedPayloadVerified: Bool
    let targetOpenSSLVerified: Bool
    let targetPythonVerified: Bool
    let runtimeTrustParity: Bool
  }

  public static func run(
    source: URL, plan planURL: URL, inputs: URL, output: URL,
    username: String = "admin", cancellation: CancellationToken? = nil
  ) throws -> BaseStageReceipt<Details> {
    let planHash = try SafeFile.sha256(planURL)
    let verified = try BaseCAInputs.load(plan: planURL, inputs: inputs, cancellation: cancellation)
    return try BaseImageStage.run(
      source: source, output: output, operation: "base-certificates", cancellation: cancellation
    ) { bundle, target, journal in
      guard target == verified.plan.target else { throw MisoError.invalid("CA target mismatch") }
      try journal.setMetadata("caPlan", value: verified.plan)
      let image = bundle.appendingPathComponent("disk.img")
      let certificates = try inspect(image, verified: verified, journal: journal)
      let root = try BaseExecutionView.prepare(image: image, target: target, journal: journal)
      var identity: [UInt32] = []
      let details = try GuestExecution.withSession(
        image: image, root: root, username: username, journal: journal
      ) { guest in
        try guest.verifyControls(target: target)
        identity = [guest.account.uid, guest.account.gid]
        return try install(verified, certificates: certificates, planHash: planHash, guest: guest)
      }
      let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
      try audit.withAttachment { session in
        let main = try BaseImageStage.mainContainer(session)
        let data = try ImageMounts.mount(
          main.volume(role: "Data"), session: session, journal: journal, name: "ca-audit",
          readOnly: true)
        let account = try BaseImageStage.Account(username, data: data)
        guard [account.uid, account.gid] == identity else {
          throw MisoError.invalid("CA account identity changed")
        }
        let path = try Artifacts.resolve(
          details.bundle, under: data.root, cancellation: journal.cancellation)
        let info = try FileMetadata.inspect(path)
        guard info.st_uid == account.uid, info.st_gid == account.gid,
          info.st_mode == S_IFREG | 0o644
        else {
          throw MisoError.invalid("CA bundle metadata differs")
        }
      }
      _ = try BaseCAInputs.load(plan: planURL, inputs: inputs, cancellation: journal.cancellation)
      guard try SafeFile.sha256(planURL) == planHash else {
        throw MisoError.invalid("CA plan changed")
      }
      return details
    }
  }

  private static func inspect(
    _ image: URL, verified: BaseCAInputs.Verified, journal: ExecutionJournal
  ) throws -> [String: Data] {
    let audit = try DiskImageSession(image: image, readOnly: true, journal: journal)
    return try audit.withAttachment { session in
      let main = try BaseImageStage.mainContainer(session)
      let system = try ImageMounts.mount(
        main.volume(role: "System"), session: session, journal: journal, name: "ca-system",
        readOnly: true)
      for record in verified.snapshot.files where record.path.hasPrefix("System/") {
        _ = try Artifacts.resolve(record, under: system.root, cancellation: journal.cancellation)
      }
      return try Dictionary(
        uniqueKeysWithValues: verified.classification.entries.filter(\.eligible).map { entry in
          let der = try SafeFile.read(system.path(entry.path), limit: 64 << 10)
          guard SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw MisoError.invalid("Invalid target X509 certificate")
          }
          return (entry.sha256.lowercased(), der)
        })
    }
  }

  private static func install(
    _ verified: BaseCAInputs.Verified, certificates: [String: Data],
    planHash: String, guest: GuestExecution
  ) throws -> Details {
    for path in [
      "Library/Keychains/System.keychain", "Library/Security/Trust Settings/Admin.plist",
    ] {
      guard !(try guest.data.contains(path)) else {
        throw MisoError.invalid("Custom system trust requires an explicit adapter")
      }
    }
    for record in verified.snapshot.files where record.path.hasPrefix("private/") {
      let digest = try guest.run(
        "ca-system-pem-digest",
        arguments: ["/usr/bin/openssl", "dgst", "-sha256", "/" + record.path])
      let size = try guest.run(
        "ca-system-pem-size", arguments: ["/usr/bin/stat", "-L", "-f", "%z", "/" + record.path])
      guard digest.split(separator: " ").last.map(String.init) == record.sha256,
        UInt64(size) == record.bytes
      else {
        throw MisoError.invalid("Target system PEM differs from snapshot")
      }
    }
    guard !(try guest.data.contains(stage)) else {
      throw MisoError.invalid("CA staging directory exists")
    }
    try guest.data.makeDirectories(stage, uid: guest.account.uid, gid: guest.account.gid)
    for (hash, der) in certificates {
      try guest.data.write(
        stage + "/" + hash + ".pem", data: Data(CertificatePEM.encode(der).utf8),
        uid: guest.account.uid, gid: guest.account.gid, mode: 0o444)
    }
    let selected = verified.classification.entries.filter { $0.included == true }
    let roots = selected.filter { $0.includedVia == nil }
    let rootPEM = try roots.map { entry -> String in
      guard let der = certificates[entry.sha256.lowercased()] else {
        throw MisoError.invalid("Missing target root")
      }
      return CertificatePEM.encode(der)
    }.joined()
    let trust = "private/tmp/miso-ca-trusted-roots.pem"
    let empty = "private/tmp/miso-ca-empty-directory"
    guard !(try guest.data.contains(trust)), !(try guest.data.contains(empty)) else {
      throw MisoError.invalid("CA control paths already exist")
    }
    try guest.data.write(
      trust, data: Data(rootPEM.utf8), uid: guest.account.uid, gid: guest.account.gid, mode: 0o444)
    try guest.data.makeDirectories(empty, uid: guest.account.uid, gid: guest.account.gid)
    defer {
      _ = unlink(guest.data.root.appendingPathComponent(trust).path)
      _ = rmdir(guest.data.root.appendingPathComponent(empty).path)
    }
    for entry in selected where entry.includedVia != nil {
      try guest.run(
        "ca-target-chain",
        arguments: [
          "/usr/bin/openssl", "verify", "-purpose", "any", "-CAfile", "/" + trust,
          "-CApath", "/" + empty, "/" + stage + "/" + entry.sha256.lowercased() + ".pem",
        ])
    }
    let filtered = try guest.run(
      "ca-target-filter", arguments: ["/bin/sh", "-c", filterProgram], capability: .base,
      timeout: 180)
    let actual = filtered.split(separator: "\n").map(String.init)
    let expected = Set(selected.map { $0.sha256.lowercased() })
    guard actual.count == expected.count, Set(actual) == expected else {
      throw MisoError.invalid("Current target CA filter differs from classification")
    }
    var merged = certificates.filter { expected.contains($0.key) }
    let link = try guest.data.path("opt/homebrew/opt/ca-certificates", allowLeafLink: true)
    let mozilla = link.appendingPathComponent("share/ca-certificates/cacert.pem")
      .resolvingSymlinksInPath()
    guard mozilla.path.hasPrefix(guest.data.root.path + "/opt/homebrew/Cellar/ca-certificates/"),
      try FileMetadata.inspect(mozilla).st_dev == guest.data.device
    else { throw MisoError.invalid("Mozilla certificate path escapes its keg") }
    for der in try CertificatePEM.decode(SafeFile.read(mozilla, limit: 16 << 20)) {
      guard SecCertificateCreateWithData(nil, der as CFData) != nil else {
        throw MisoError.invalid("Invalid Mozilla X509 certificate")
      }
      merged[SafeFile.sha256(der)] = der
    }
    let pem = merged.keys.sorted().map { CertificatePEM.encode(merged[$0]!) }.joined(
      separator: "\n")
    try guest.data.write(
      destination, data: Data(pem.utf8), uid: guest.account.uid, gid: guest.account.gid)
    let python =
      "/opt/homebrew/opt/\(verified.plan.pythonFormula)/bin/\(verified.plan.pythonExecutable)"
    let count = try guest.run(
      "ca-target-python",
      arguments: [
        python, "-I", "-c",
        "import ssl; print(ssl.create_default_context().cert_store_stats()['x509_ca'])",
      ], capability: .base)
    guard Int(count) == merged.count else {
      throw MisoError.invalid("Target Python CA count differs")
    }
    return Details(
      plan: verified.plan, planSHA256: planHash, certificateFingerprints: merged.keys.sorted(),
      systemRootCount: expected.count,
      bundle: try Artifacts.record(guest.data.path(destination), relativeTo: guest.data.root),
      detachedPayloadVerified: true,
      targetOpenSSLVerified: true, targetPythonVerified: true, runtimeTrustParity: false)
  }

  private static let filterProgram = """
    for cert in /opt/homebrew/var/miso-root-certificates/*.pem; do
      /usr/bin/openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 || continue
      /usr/bin/openssl x509 -in "$cert" -purpose -noout | /usr/bin/grep -Fq 'SSL server CA : Yes' || continue
      /usr/bin/basename "$cert" .pem
    done
    """
}

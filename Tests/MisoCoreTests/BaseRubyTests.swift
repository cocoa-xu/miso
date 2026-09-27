import Foundation
import Testing

@testable import MisoCore

private func rubyBuild(_ version: String = "4.0.7") -> BaseRuby.Build {
  .init(
    version: version, opensslFormula: "openssl@3",
    sources: [
      .init(path: "ruby-\(version).tar.gz", bytes: 10, sha256: String(repeating: "a", count: 64))
    ])
}

@Test func rubyToolchainUsesTargetNotHost() throws {
  for (version, build, deployment, triplet) in [
    ("15.6.1", "24G90", "15.0", "aarch64-apple-darwin24"),
    ("26.6.2", "25G83", "26.0", "aarch64-apple-darwin25"),
  ] {
    let result = try BaseRuby.Toolchain(.init(version: version, build: build))
    #expect(result.deployment == deployment)
    #expect(result.triplet == triplet)
    #expect(result.clangTarget == "arm64-apple-macos" + deployment)
  }
  #expect(throws: (any Error).self) {
    try BaseRuby.Toolchain(.init(version: "26.6.2", build: "27A1"))
  }
}

@Test func rubyPlansBoundVersionsConcurrencyAndInputs() throws {
  let target = MacOSRelease(version: "26.6.2", build: "25G83")
  try BaseRuby.Plan(
    schemaVersion: 1, target: target, builds: [rubyBuild()], defaultVersion: "4.0.7", jobs: 4
  ).validate()
  for (builds, defaultVersion, jobs) in [
    ([], "4.0.7", 4), ([rubyBuild(), rubyBuild()], "4.0.7", 4),
    ([rubyBuild()], "2.7.8", 4), ([rubyBuild()], "4.0.7", 0),
    ([rubyBuild()], "4.0.7", 9), ([rubyBuild("../4.0.7")], "../4.0.7", 4),
  ] {
    #expect(throws: (any Error).self) {
      try BaseRuby.Plan(
        schemaVersion: 1, target: target, builds: builds,
        defaultVersion: defaultVersion, jobs: jobs
      ).validate()
    }
  }
  #expect(throws: (any Error).self) {
    try BaseRuby.Build(
      version: "4.0.7", opensslFormula: "openssl@3 --bad", sources: rubyBuild().sources
    ).validate()
  }
}

@Test func rubyVendoredOpenSSLRequiresBoundedNamedArchive() throws {
  let ruby = rubyBuild("2.7.8")
  let openssl = ImageBundle.FileRecord(
    path: "openssl-1.1.1w.tar.gz", bytes: 10,
    sha256: String(repeating: "b", count: 64))
  try BaseRuby.Build(version: ruby.version, opensslFormula: nil, sources: ruby.sources + [openssl])
    .validate()
  #expect(throws: (any Error).self) {
    try BaseRuby.Build(version: ruby.version, opensslFormula: nil, sources: ruby.sources).validate()
  }
  #expect(throws: (any Error).self) {
    try BaseRuby.Build(
      version: ruby.version, opensslFormula: "openssl@3", sources: ruby.sources + [openssl]
    ).validate()
  }
}

@Test func rubyProbesRejectHostKernelContamination() throws {
  let toolchain = try BaseRuby.Toolchain(.init(version: "26.6.2", build: "25G83"))
  let probe = BaseRuby.Probe(
    version: "4.0.7", platform: "arm64-darwin25",
    host: "aarch64-apple-darwin25", openssl: "OpenSSL 3.6.4", psych: "0.2.5", zlib: "1.2.12")
  let text = String(decoding: try JSON.encode(probe), as: UTF8.self)
  #expect(
    try BaseRuby.validateProbe(text, build: rubyBuild(), toolchain: toolchain).version == "4.0.7")
  #expect(
    try BaseRuby.validateProbe(
      text.replacingOccurrences(of: "aarch64-apple", with: "arm64-apple"),
      build: rubyBuild(), toolchain: toolchain
    ).host == "arm64-apple-darwin25")
  #expect(throws: (any Error).self) {
    try BaseRuby.validateProbe(
      text.replacingOccurrences(of: "darwin25", with: "darwin27"),
      build: rubyBuild(), toolchain: toolchain)
  }
  #expect(throws: (any Error).self) {
    try BaseRuby.validateProbe(text, build: rubyBuild("2.7.8"), toolchain: toolchain)
  }
}

@Test func rubyInputVerificationRejectsChangedPayloads() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let payload = temporary.url.appendingPathComponent("ruby-4.0.7.tar.gz")
  try SafeFile.writeNew(Data("ruby-source".utf8), to: payload)
  let record = try Artifacts.record(payload, relativeTo: temporary.url)
  let plan = BaseRuby.Plan(
    schemaVersion: 1, target: .init(version: "26.6.2", build: "25G83"),
    builds: [.init(version: "4.0.7", opensslFormula: "openssl@3", sources: [record])],
    defaultVersion: "4.0.7", jobs: 4)
  let planURL = temporary.url.appendingPathComponent("plan.json")
  try SafeFile.writeNew(JSON.encode(plan), to: planURL)
  #expect(try BaseRuby.verify(plan: planURL, inputs: temporary.url).builds.count == 1)
  try SafeFile.replace(Data("changed".utf8), at: payload)
  #expect(throws: (any Error).self) { try BaseRuby.verify(plan: planURL, inputs: temporary.url) }
}

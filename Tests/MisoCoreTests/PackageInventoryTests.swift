import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func cltPreflightRejectsMissingAndChangedInputsWithoutCreatingOutputs() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let profile = RestoreProfile.supported[1]
  #expect(throws: (any Error).self) {
    try CommandLineTools.validateInputs(packages: directory.url, profile: profile)
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
  let first = try #require(CLTPins.packages[profile.commandLineTools.product]?.first)
  try SafeFile.writeNew(Data([1]), to: directory.url.appendingPathComponent(first.filename))
  #expect(throws: (any Error).self) {
    try CommandLineTools.validateInputs(packages: directory.url, profile: profile)
  }
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == [first.filename])
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["MISO_CLT_PACKAGES"] != nil
      && ProcessInfo.processInfo.environment["MISO_CLT_OUTPUT"] != nil))
func pinnedCLTPackagesPassNativePreparation() throws {
  let environment = ProcessInfo.processInfo.environment
  let build = environment["MISO_CLT_BUILD"] ?? "25G83"
  let profile = try #require(RestoreProfile.supported.first { $0.release.build == build })
  let packages = URL(fileURLWithPath: try #require(environment["MISO_CLT_PACKAGES"]))
  let output = URL(fileURLWithPath: try #require(environment["MISO_CLT_OUTPUT"]))
  let journal = try ExecutionJournal(output: output, operation: "verify-clt-packages")
  try journal.setMetadata("target", value: profile.release)
  _ = try journal.perform {
    let prepared = try CommandLineTools.prepare(
      packages: packages, profile: profile, journal: journal)
    #expect(prepared.packages.count == 9)
    #expect(prepared.expansions.count == 9)
    #expect(prepared.entries.count > 1_000)
    return prepared.packages
  }
}

@Test func cltProfilesContainUniquePinnedPackages() throws {
  for profile in RestoreProfile.supported {
    let packages = try #require(CLTPins.packages[profile.commandLineTools.product])
    #expect(packages.count == 9)
    #expect(Set(packages.map(\.filename)).count == 9)
    #expect(Set(packages.map(\.identifier)).count == 9)
    for package in packages {
      try SafeFile.validateSHA256(package.sha256)
      #expect(package.identifier.hasPrefix("com.apple.pkg.CLTools_"))
      #expect(
        package.version.hasPrefix(
          profile.family == .sequoia ? "16.4." : profile.family == .tahoe ? "26.6." : "27.0."))
    }
  }
  for controls in CLTPins.sizes.values {
    for (path, control) in controls {
      #expect(path.hasPrefix(PackageInventory.root + "/"))
      #expect(control.bomBytes != control.payloadBytes)
      try SafeFile.validateSHA256(control.sha256)
    }
  }
}

@Test func packageBOMRejectsEscapesDuplicatePathsAndLinkParents() throws {
  let root = PackageInventory.root
  let directory = "./\(root)\t40755\t0\t80\t\t\n"
  let file = "./\(root)/value\t100644\t0\t0\t4\t\n"
  let entries = try PackageInventory.parse(directory + file)
  #expect(entries.count == 2 && entries[root + "/value"]?.size == 4)
  for bad in [
    file + file,
    "./../escape\t100644\t0\t0\t4\t\n",
    "./\(root)/bad\t104644\t0\t0\t4\t\n",
    "./\(root)/bad\t100644\t501\t0\t4\t\n",
    "./\(root)/bad\t120755\t0\t0\t\t/etc/passwd\n",
    "./\(root)/bad\t120755\t0\t0\t\t../../../../etc/passwd\n",
    "./\(root)/link\t120755\t0\t0\t\tvalue\n./\(root)/link/child\t100644\t0\t0\t4\t\n",
    "./private/etc/passwd\t100644\t0\t0\t4\t\n",
  ] {
    #expect(throws: (any Error).self) { try PackageInventory.parse(bad) }
  }
}

@Test func packageDirectoryOverridesAreProfileBounded() throws {
  let left = PackageInventory.Entry(mode: S_IFDIR | 0o755, uid: 0, gid: 0, link: "")
  var right = left
  right.gid = 80
  let tahoe = RestoreProfile.supported[1]
  #expect(
    try PackageInventory.merge(left, right, relative: PackageInventory.root, profile: tahoe).gid
      == 80)
  #expect(throws: (any Error).self) {
    try PackageInventory.merge(
      left, right, relative: PackageInventory.root + "/unlisted", profile: tahoe)
  }
  #expect(throws: (any Error).self) {
    try PackageInventory.merge(
      left, right, relative: PackageInventory.root, profile: RestoreProfile.supported[0])
  }
}

@Test func packageInfoRequiresExactIdentifierVersionAndCompression() throws {
  let package = try #require(CLTPins.packages["140-17812"]?.first)
  let valid =
    "<pkg-info identifier=\"\(package.identifier)\" version=\"\(package.version)\" useHFSPlusCompression=\"true\"/>"
  try PackageInventory.validateInfo(Data(valid.utf8), package: package)
  for bad in [
    valid.replacingOccurrences(of: package.version, with: "0"),
    valid.replacingOccurrences(of: "true", with: "false"),
    valid.replacingOccurrences(of: package.identifier, with: "other"),
  ] {
    #expect(throws: (any Error).self) {
      try PackageInventory.validateInfo(Data(bad.utf8), package: package)
    }
  }
}

@Test func cltDestinationPreservesBetaPlaceholderAndRejectsInstalledFiles() throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let data = try GuestVolume(temporary.url)
  #expect(try CommandLineTools.validateDestination(data).isEmpty)
  let root = temporary.url.appendingPathComponent(PackageInventory.root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let marker = root.appendingPathComponent(".beta")
  try Data("1\n".utf8).write(to: marker)
  #expect(try CommandLineTools.validateDestination(data) == [PackageInventory.root])
  #expect(try Data(contentsOf: marker) == Data("1\n".utf8))
  let installed = root.appendingPathComponent("usr")
  try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: false)
  #expect(throws: (any Error).self) { try CommandLineTools.validateDestination(data) }
  #expect(FileManager.default.fileExists(atPath: installed.path))
  try FileManager.default.removeItem(at: installed)
  let receipts = temporary.url.appendingPathComponent("Library/Apple/System/Library/Receipts")
  try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
  try Data().write(to: receipts.appendingPathComponent("com.apple.pkg.CLTools_Executables.plist"))
  #expect(throws: (any Error).self) { try CommandLineTools.validateDestination(data) }
}

@Test(arguments: ["empty", "changed-marker", "marker-symlink", "root-symlink"])
func cltDestinationRejectsUnrecognizedOrLinkedPlaceholders(kind: String) throws {
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  let root = temporary.url.appendingPathComponent(PackageInventory.root)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let external = temporary.url.appendingPathComponent("external")
  try Data("1\n".utf8).write(to: external)
  if kind == "changed-marker" {
    try Data("0\n".utf8).write(to: root.appendingPathComponent(".beta"))
  } else if kind == "marker-symlink" {
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(".beta"), withDestinationURL: external)
  } else if kind == "root-symlink" {
    try FileManager.default.removeItem(at: root)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: temporary.url)
  }
  #expect(throws: (any Error).self) {
    try CommandLineTools.validateDestination(GuestVolume(temporary.url))
  }
  #expect(try Data(contentsOf: external) == Data("1\n".utf8))
}

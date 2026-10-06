import Foundation

enum HomebrewLifecycle {
  struct Probe: Equatable {
    let name: String
    let arguments: [String]
  }

  static let postInstallProgram = """
    require "formula"
    require "formulary"
    require "extend/pathname/write_mkpath_extension"
    Pathname.activate_extensions!
    formula = Formulary.factory(ARGV.fetch(0))
    abort "Post-install method unavailable" unless formula.respond_to?(:run_post_install)
    formula.run_post_install
    """

  static func run(
    _ formulae: [HomebrewResolution.Formula], guest: GuestExecution, execution: HomebrewExecution
  ) throws
    -> [String: String]
  {
    for formula in formulae where formula.hasPostInstall {
      try guest.run(
        "formula-post-install",
        arguments: GuestExecution.brewArguments(
          execution.rubyArguments(program: postInstallProgram, arguments: [formula.name]),
          username: guest.account.username),
        capability: .brew, timeout: 180,
        progress: "Run post-install for \(formula.name) \(formula.kegVersion)")
    }
    var results: [String: String] = [:]
    for probe in try probes(formulae) {
      let output = try guest.run(
        "formula-probe", arguments: probe.arguments,
        capability: .base, timeout: 180, progress: "Check tool \(probe.name)")
      guard !output.isEmpty else { throw MisoError.invalid("Empty formula probe: \(probe.name)") }
      results[probe.name] = output
    }
    let missing = try guest.run(
      "formula-missing",
      arguments: GuestExecution.brewArguments(
        ["missing"], username: guest.account.username), capability: .brew, timeout: 180,
      progress: "Check Homebrew dependencies")
    guard missing.isEmpty else { throw MisoError.invalid("Homebrew reports missing dependencies") }
    results["linkage"] = try guest.run(
      "formula-linkage",
      arguments: GuestExecution.brewArguments(
        ["linkage", "--test"], username: guest.account.username), capability: .brew, timeout: 300,
      progress: "Check Homebrew library linkage")
    return results
  }

  static func probes(_ formulae: [HomebrewResolution.Formula]) throws -> [Probe] {
    var probes: [Probe] = []
    for formula in formulae {
      try PackageRequest(name: formula.name, version: formula.version).validate()
      let bin = "/opt/homebrew/opt/\(formula.name)/bin/"
      if formula.name == "node" || formula.name.hasPrefix("node@") {
        probes.append(
          Probe(
            name: formula.name,
            arguments: [
              bin + "node", "-e",
              "if(process.version!==\"v\(formula.version)\"||process.arch!==\"arm64\"||process.platform!==\"darwin\")process.exit(1);console.log(process.version)",
            ]))
        probes.append(
          Probe(
            name: formula.name + "-npm",
            arguments: [
              "/usr/bin/env",
              "PATH=\(bin):/opt/homebrew/bin:/usr/bin:/bin", bin + "npm", "--version",
            ]))
      } else if formula.name.hasPrefix("python@") {
        let version = try StableVersion(formula.version)
        let executable = "python\(version.components[0]).\(version.components[1])"
        probes.append(
          Probe(
            name: formula.name,
            arguments: [
              bin + executable, "-I", "-c",
              "import ssl,sqlite3,zlib; print(ssl.OPENSSL_VERSION,sqlite3.sqlite_version,zlib.ZLIB_VERSION)",
            ]))
      } else if let executable = [
        "awscli": "aws", "curl": "curl", "rbenv": "rbenv", "ruby-build": "ruby-build",
      ][formula.name] {
        probes.append(Probe(name: formula.name, arguments: [bin + executable, "--version"]))
      }
    }
    probes += [
      Probe(
        name: "clang",
        arguments: ["/Library/Developer/CommandLineTools/usr/bin/clang", "--version"]),
      Probe(
        name: "sdk",
        arguments: [
          "/usr/bin/env", "DEVELOPER_DIR=/Library/Developer/CommandLineTools",
          "/usr/bin/xcrun", "--show-sdk-path",
        ]),
    ]
    return probes
  }
}

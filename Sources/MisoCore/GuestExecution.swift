import Darwin
import Foundation

final class GuestExecution {
  enum Capability: String {
    case readOnly = "read-only"
    case base, ruby, git, brew
  }
  let root: URL
  let data: GuestVolume
  let account: BaseImageStage.Account
  let journal: ExecutionJournal
  private let executable: URL
  private let executableSHA256: String

  private init(
    root: URL, data: GuestVolume, account: BaseImageStage.Account, journal: ExecutionJournal
  ) throws {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
      throw MisoError.invalid("Cannot locate native execution helper")
    }
    self.root = root
    self.data = data
    self.account = account
    self.journal = journal
    self.executable = executable
    executableSHA256 = try SafeFile.sha256(executable)
  }

  static func withSession<T>(
    image: URL, root: URL, username: String, journal: ExecutionJournal,
    body: (GuestExecution) throws -> T
  ) throws -> T {
    let session = try DiskImageSession(image: image, readOnly: false, journal: journal)
    return try session.withAttachment { session in
      let main = try BaseImageStage.mainContainer(session)
      let data = try ImageMounts.mount(
        main.volume(role: "Data"), session: session, journal: journal,
        name: "execution-data", readOnly: false,
        at: root.appendingPathComponent("System/Volumes/Data"), restricted: true)
      let preboot = try ImageMounts.mount(
        main.volume(role: "Preboot"), session: session, journal: journal,
        name: "execution-preboot", readOnly: true,
        at: root.appendingPathComponent("System/Volumes/Preboot"), restricted: true)
      let account = try BaseImageStage.Account(username, data: data)
      var images: [URL] = []
      for name in try FileManager.default.contentsOfDirectory(atPath: preboot.root.path)
      where UUID(uuidString: name) != nil {
        let candidate = preboot.root.appendingPathComponent(name + "/cryptex1/current/os.dmg")
          .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(preboot.root.path + "/") else {
          throw MisoError.invalid("OS Cryptex escapes Preboot")
        }
        if FileManager.default.fileExists(atPath: candidate.path) { images.append(candidate) }
      }
      guard images.count == 1 else { throw MisoError.invalid("Missing or ambiguous OS Cryptex") }
      let cryptex = try DiskImageSession(image: images[0], readOnly: true, journal: journal)
      let cryptexMount = try preboot.path("Cryptexes/OS")
      return try cryptex.withAttachment(
        requireGPT: false, mountPoint: cryptexMount, existingEmptyMountPoint: true
      ) { cryptex in
        var cryptexInfo = statfs()
        guard statfs(cryptexMount.path, &cryptexInfo) == 0 else {
          throw MisoError.system("Inspect execution Cryptex", errno)
        }
        if cryptexInfo.f_flags & UInt32(MNT_NOSUID) == 0 {
          try journal.run(
            "restrict-execution-cryptex",
            NativeCommand(
              .mount,
              arguments: ["-u", "-o", "rdonly,nosuid,nobrowse", cryptexMount.path]))
        }
        try cryptex.verifyOwnership()
        guard
          cryptex.attachment?.entities.filter({ $0.mountPoint == cryptexMount.path }).count == 1,
          statfs(cryptexMount.path, &cryptexInfo) == 0,
          cryptexInfo.f_flags & UInt32(MNT_NOSUID | MNT_RDONLY) == UInt32(MNT_NOSUID | MNT_RDONLY)
        else {
          throw MisoError.invalid("Execution Cryptex mount is not read-only and nosuid")
        }
        let dev = root.appendingPathComponent("dev")
        _ = try GuestVolume(dev)
        guard try FileManager.default.contentsOfDirectory(atPath: dev.path).isEmpty else {
          throw MisoError.invalid("Device mount point is not empty")
        }
        try journal.run(
          "mount-execution-devfs",
          NativeCommand(.mount, arguments: ["-t", "devfs", "-o", "nosuid", "devfs", dev.path]))
        func unmount() throws {
          var info = statfs()
          guard statfs(dev.path, &info) == 0 else {
            throw MisoError.system("Inspect execution devfs", errno)
          }
          let mountedAt = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
          }
          let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
              String(cString: $0)
            }
          }
          guard mountedAt == dev.path, type == "devfs", info.f_flags & UInt32(MNT_NOSUID) != 0
          else {
            throw MisoError.invalid("Execution device mount ownership changed")
          }
          try journal.run(
            "unmount-execution-devfs", NativeCommand(.unmount, arguments: [dev.path]), cleanup: true
          )
        }
        do {
          let execution = try GuestExecution(
            root: root, data: data, account: account, journal: journal)
          let result = try body(execution)
          try unmount()
          return result
        } catch {
          let original = error
          do { try unmount() } catch {
            throw MisoError.invalid(
              "\(original.localizedDescription); devfs cleanup failed: \(error.localizedDescription)"
            )
          }
          throw original
        }
      }
    }
  }

  @discardableResult
  func run(
    _ name: String, arguments: [String], capability: Capability = .readOnly,
    timeout: TimeInterval = 90, expectedExitCodes: Set<Int32> = [0]
  ) throws -> String {
    guard try SafeFile.sha256(executable) == executableSHA256 else {
      throw MisoError.invalid("Native execution helper changed")
    }
    let argv =
      [
        "_guest-exec", "--root", root.path, "--uid", String(account.uid), "--gid",
        String(account.gid),
        "--username", account.username, "--capability", capability.rawValue,
      ] + arguments
    let log = try journal.run(
      name, NativeCommand(executable.path, arguments: argv, timeout: timeout),
      expectedExitCodes: expectedExitCodes)
    guard let text = String(data: try SafeFile.read(log, limit: 8 << 20), encoding: .utf8) else {
      throw MisoError.invalid("Invalid guest command output")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func verifyControls(target: MacOSRelease) throws {
    guard try run("guest-build", arguments: ["/usr/bin/sw_vers", "-buildVersion"]) == target.build,
      try run("guest-user", arguments: ["/usr/bin/id", "-u"]) == String(account.uid),
      try run(
        "guest-nested-exec", arguments: ["/bin/sh", "-c", "/bin/bash -c 'printf native-target-ok'"])
        == "native-target-ok"
    else { throw MisoError.invalid("Guest execution identity control failed") }
    let marker = "opt/homebrew/.miso-write-control"
    let outside = "Users/\(account.username)/.miso-outside-control"
    guard !(try data.contains(marker)), !(try data.contains(outside)) else {
      throw MisoError.invalid("Control paths already exist")
    }
    try run(
      "guest-allowed-write", arguments: ["/bin/sh", "-c", "printf allowed > /\(marker)"],
      capability: .base)
    guard try SafeFile.read(data.path(marker), limit: 64) == Data("allowed".utf8) else {
      throw MisoError.invalid("Allowed write did not reach target Data")
    }
    try run(
      "guest-readonly-denial", arguments: ["/bin/sh", "-c", "printf denied > /\(marker)"],
      expectedExitCodes: [1, 2])
    try run(
      "guest-outside-denial", arguments: ["/bin/sh", "-c", "printf denied > /\(outside)"],
      capability: .base, expectedExitCodes: [1, 2])
    guard !(try data.contains(outside)),
      try SafeFile.read(data.path(marker), limit: 64) == Data("allowed".utf8)
    else {
      throw MisoError.invalid("Guest write restrictions failed")
    }
    guard unlink(try data.path(marker).path) == 0 else {
      throw MisoError.system("Remove guest control marker", errno)
    }
    try run(
      "guest-privilege-denial", arguments: ["/usr/bin/sudo", "-n", "/usr/bin/id", "-u"],
      expectedExitCodes: [1])
    try run(
      "guest-bootstrap-denial", arguments: ["/bin/launchctl", "print", "system"],
      expectedExitCodes: [1, 113, 141])
  }

  static func brewArguments(_ arguments: [String], username: String) -> [String] {
    [
      "/bin/sh", "-c", "exec \"$@\"", "base-install", "/usr/bin/env",
      "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_INSTALL_FROM_API=1",
      "HOMEBREW_NO_BOOTSNAP=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_ENV_HINTS=1",
      "HOMEBREW_DEVELOPER=1",
      "HOMEBREW_CACHE=/Users/\(username)/Library/Caches/Homebrew",
      "HOMEBREW_LOGS=/Users/\(username)/Library/Caches/Homebrew/Logs",
      "HOMEBREW_TEMP=/private/tmp", "/opt/homebrew/bin/brew",
    ] + arguments
  }
}

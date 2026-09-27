import Darwin
import Foundation

enum BaseCaptureReminder {
  static let client = "/usr/libexec/sshd-keygen-wrapper"
  static let directory = "Library/Group Containers/group.com.apple.replayd"
  static let filename = "ScreenCaptureApprovals.plist"

  struct Policy: Codable {
    let schemaVersion: Int
    let replaydSHA256: String
    let expiresAt: Date

    func validate(target: MacOSRelease, now: Date = Date()) throws {
      guard schemaVersion == 1, try MacOSVersion(target.version).major == 26 else {
        throw MisoError.unsupported("Screen capture reminder policy requires a macOS 26 profile")
      }
      try SafeFile.validateSHA256(replaydSHA256)
      guard expiresAt.timeIntervalSince1970.isFinite, expiresAt > now else {
        throw MisoError.invalid("Screen capture reminder policy must have a future expiry")
      }
    }

    func verifyImplementation(_ replayd: URL) throws {
      guard try SafeFile.sha256(replayd) == replaydSHA256 else {
        throw MisoError.invalid("Target capture implementation differs from plan")
      }
    }

    var preferences: [String: Any] {
      [
        client: [
          "kScreenCaptureAlertableUsageCount": 1,
          "kScreenCaptureApprovalLastAlerted": expiresAt,
          "kScreenCaptureApprovalLastUsed": expiresAt,
          "kScreenCapturePrivacyHintDate": expiresAt,
          "kScreenCapturePrivacyHintPolicy": 2_592_000,
        ]
      ]
    }
  }

  static func seed(
    _ policy: Policy, data: GuestVolume, home: String, uid: uid_t, gid: gid_t,
    grants: [BaseTCC.Grant]
  ) throws -> String {
    guard
      grants.contains(where: { $0.service == "kTCCServiceScreenCapture" && $0.client == client })
    else { throw MisoError.invalid("Capture reminder client has no declared screen capture grant") }
    let path = home + "/" + directory + "/" + filename
    guard !(try data.contains(path)) else {
      throw MisoError.invalid("Existing capture reminders require an explicit merge profile")
    }
    for relative in [home + "/Library/Group Containers", home + "/" + directory] {
      let existed = try data.contains(relative)
      try data.makeDirectories(relative, uid: uid, gid: gid)
      let url = try data.directory(relative).url
      if !existed, chmod(url.path, 0o700) != 0 {
        throw MisoError.system("Set capture reminder directory mode", errno)
      }
      try BaseTCC.verifyDirectory(url, uid: uid, gid: gid, userOwned: true)
    }
    try data.write(
      path,
      data: PropertyListSerialization.data(
        fromPropertyList: policy.preferences, format: .binary, options: 0),
      uid: uid, gid: gid, mode: 0o600)
    return path
  }

  static func verify(_ url: URL, uid: uid_t, gid: gid_t) throws {
    let parent = url.deletingLastPathComponent()
    for directory in [parent, parent.deletingLastPathComponent()] {
      try BaseTCC.verifyDirectory(directory, uid: uid, gid: gid, userOwned: true)
    }
    let info = try FileMetadata.inspect(url)
    guard info.st_mode == S_IFREG | 0o600, info.st_uid == uid, info.st_gid == gid else {
      throw MisoError.invalid("Capture reminder ownership or mode differs")
    }
  }
}

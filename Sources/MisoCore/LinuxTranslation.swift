import Darwin
import Foundation

enum LinuxTranslation {
  static func configure(data: GuestVolume, profile: RestoreProfile, include: Bool) throws {
    let directory = "Library/Apple/usr/libexec/oah/RosettaLinux"
    guard profile.containsLinuxTranslation else {
      guard !include else {
        throw MisoError.unsupported("Linux translation in this restore profile")
      }
      return
    }
    let files: [(String, UInt64, String)] = [
      ("rosetta", 1_726_424, "723a1aee626399b5620cbf46f11637d6b7fa79777b23e0ad4d1c9ae2a45f241b"),
      ("rosettad", 393_224, "bdd8b761ffa9d4f4e9cadeed5dd6403c02a1989b36a04de4d19de13bff44d842"),
    ]
    for (relative, expected) in [
      (directory, Set(files.map(\.0))), ("Library/Apple/usr/libexec/oah", Set(["RosettaLinux"])),
    ] {
      let path = try data.path(relative)
      let info = try FileMetadata.inspect(path)
      guard info.st_mode == S_IFDIR | 0o755, info.st_uid == 0, info.st_gid == 0,
        try Set(FileManager.default.contentsOfDirectory(atPath: path.path)) == expected
      else { throw MisoError.invalid("Unexpected Linux translation directory") }
    }
    for (name, size, checksum) in files {
      let path = try data.path(directory + "/" + name)
      let info = try FileMetadata.inspect(path)
      guard info.st_mode == S_IFREG | 0o755, info.st_uid == 0, info.st_gid == 0,
        info.st_size == size, try SafeFile.sha256(path) == checksum
      else { throw MisoError.invalid("Linux translation content differs from profile") }
    }
    if include { return }
    for (name, _, _) in files {
      guard unlink(try data.path(directory + "/" + name).path) == 0 else {
        throw MisoError.system("Remove excluded Linux translation", errno)
      }
    }
    for relative in [directory, "Library/Apple/usr/libexec/oah"] {
      guard rmdir(try data.path(relative).path) == 0 else {
        throw MisoError.system("Remove empty Linux translation directory", errno)
      }
    }
  }
}

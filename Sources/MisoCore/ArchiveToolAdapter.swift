import Darwin
import Foundation

enum ArchiveToolAdapter {
  static let directory = "Library/Developer/CommandLineTools/usr/bin"
  static let wrapper = """
    #!/bin/sh
    set -eu
    archive_tool=${0##*/}
    case "$archive_tool" in libtool|ranlib) ;; *) exit 64 ;; esac
    archive_tmp=$(/usr/bin/mktemp -d /private/tmp/miso-archive.XXXXXX)
    trap '/bin/rm -f "$archive_tmp/$archive_tool"; /bin/rmdir "$archive_tmp"' EXIT
    /bin/cp /Library/Developer/CommandLineTools/usr/bin/.miso-libtool "$archive_tmp/$archive_tool"
    /usr/bin/env DYLD_LIBRARY_PATH=/Library/Developer/CommandLineTools/usr/lib "$archive_tmp/$archive_tool" "$@"
    """ + "\n"

  struct State {
    let volume: GuestVolume
    let toolSHA256: String
    let wrapperSHA256: String
  }

  static func withView<T>(
    _ root: URL, target: MacOSRelease, journal: ExecutionJournal, body: () throws -> T
  ) throws -> T {
    guard target.build == "25G83" else { return try body() }
    let state = try install(root)
    do {
      try journal.setMetadata(
        "archiveToolAdapter",
        value: [
          "toolSHA256": state.toolSHA256, "wrapperSHA256": state.wrapperSHA256,
          "scope": "temporary-execution-view",
        ])
      let result = try body()
      try restore(state)
      try journal.setMetadata("archiveToolAdapterRestored", value: true)
      return result
    } catch {
      let original = error
      do {
        try restore(state)
        try journal.setMetadata("archiveToolAdapterRestored", value: true)
      } catch {
        throw MisoError.invalid(
          "\(original.localizedDescription); archive adapter cleanup failed: \(error.localizedDescription)"
        )
      }
      throw original
    }
  }

  static func install(_ root: URL) throws -> State {
    let volume = try GuestVolume(root)
    let tool = try volume.path(directory + "/libtool")
    let alias = try volume.path(directory + "/ranlib", allowLeafLink: true)
    let backup = try volume.path(directory + "/.miso-libtool")
    guard try FileMetadata.inspect(alias).st_mode & S_IFMT == S_IFLNK,
      try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == "libtool",
      try !volume.contains(directory + "/.miso-libtool"),
      try BaseExecutionView.isExecutable(tool)
    else { throw MisoError.invalid("Unexpected temporary archive tool layout") }
    let bytes = Data(wrapper.utf8)
    let state = State(
      volume: volume, toolSHA256: try SafeFile.sha256(tool), wrapperSHA256: SafeFile.sha256(bytes))
    guard rename(tool.path, backup.path) == 0 else {
      throw MisoError.system("Preserve execution libtool", errno)
    }
    do {
      guard unlink(alias.path) == 0 else {
        throw MisoError.system("Replace execution archive alias", errno)
      }
      for destination in [alias, tool] {
        try SafeFile.writeNew(bytes, to: destination)
        guard chmod(destination.path, 0o755) == 0 else {
          throw MisoError.system("Set archive adapter permissions", errno)
        }
      }
      return state
    } catch {
      let original = error
      do { try restore(state) } catch {
        throw MisoError.invalid(
          "\(original.localizedDescription); archive adapter installation cleanup failed: \(error.localizedDescription)"
        )
      }
      throw original
    }
  }

  static func restore(_ state: State) throws {
    let volume = state.volume
    let backup = try volume.path(directory + "/.miso-libtool")
    for name in ["ranlib", "libtool"] {
      let file = try volume.path(directory + "/" + name, allowLeafLink: true)
      var info = stat()
      if lstat(file.path, &info) != 0 {
        guard errno == ENOENT else { throw MisoError.system("Inspect archive adapter", errno) }
        continue
      }
      if name == "ranlib", info.st_mode & S_IFMT == S_IFLNK,
        try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == "libtool"
      {
        continue
      }
      guard info.st_mode & S_IFMT == S_IFREG else {
        throw MisoError.invalid("Archive adapter identity changed")
      }
      let digest = try SafeFile.sha256(file)
      if name == "libtool", digest == state.toolSHA256,
        try !volume.contains(directory + "/.miso-libtool")
      {
        continue
      }
      guard digest == state.wrapperSHA256 else {
        throw MisoError.invalid("Archive adapter bytes changed")
      }
      guard unlink(file.path) == 0 else { throw MisoError.system("Remove archive adapter", errno) }
    }
    let tool = try volume.path(directory + "/libtool")
    if try volume.contains(directory + "/.miso-libtool") {
      guard try SafeFile.sha256(backup) == state.toolSHA256,
        try !volume.contains(directory + "/libtool"), rename(backup.path, tool.path) == 0
      else { throw MisoError.invalid("Cannot restore execution libtool") }
    }
    guard try SafeFile.sha256(tool) == state.toolSHA256 else {
      throw MisoError.invalid("Restored archive tool differs")
    }
    let alias = try volume.path(directory + "/ranlib", allowLeafLink: true)
    var info = stat()
    if lstat(alias.path, &info) != 0 {
      guard errno == ENOENT, symlink("libtool", alias.path) == 0 else {
        throw MisoError.system("Restore archive alias", errno)
      }
    }
    guard try FileMetadata.inspect(alias).st_mode & S_IFMT == S_IFLNK,
      try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == "libtool"
    else { throw MisoError.invalid("Restored archive alias differs") }
  }
}

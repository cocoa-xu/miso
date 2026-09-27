import Darwin
import Foundation

enum BaseExecutionView {
  enum Mode: String, Codable {
    case mountedSystem
    case copiedTools

    static func select(_ target: MacOSRelease, hostBuild: String? = nil) throws -> Self {
      switch try RestoreProfile.select(target).family {
      case .sequoia: return .mountedSystem
      case .tahoe: return .copiedTools
      case .goldenGate:
        let host = try hostBuild ?? HostInfo.current().productBuild
        return target.build == "26A434" && host == "26A428" ? .copiedTools : .mountedSystem
      }
    }
  }

  struct Prepared {
    let root: URL
    let target: MacOSRelease
    let mode: Mode
  }

  struct Executable: Codable {
    let path: String
    let originalSHA256: String
    let executionSHA256: String
  }

  static func prepare(image: URL, target: MacOSRelease, journal: ExecutionJournal) throws
    -> Prepared
  {
    try journal.measure("executionViewSeconds") {
      let mode = try Mode.select(target)
      try journal.setMetadata("executionViewMode", value: mode)
      let root: URL
      switch mode {
      case .copiedTools:
        root = try create(image: image, target: target, journal: journal)
      case .mountedSystem:
        root = journal.output.appendingPathComponent("execution-root")
        try SafeFile.makeDirectory(root)
        guard chown(root.path, 0, 0) == 0, chmod(root.path, 0o755) == 0 else {
          throw MisoError.system("Prepare execution mount point", errno)
        }
        try journal.setMetadata("executionTools", value: 0)
        try journal.setMetadata("outputSystemModified", value: false)
      }
      return Prepared(root: root, target: target, mode: mode)
    }
  }

  private static func create(image: URL, target: MacOSRelease, journal: ExecutionJournal) throws
    -> URL
  {
    let root = journal.output.appendingPathComponent("execution-root")
    try SafeFile.makeDirectory(root)
    guard chmod(root.path, 0o700) == 0 else {
      throw MisoError.system("Restrict execution root", errno)
    }
    try Artifacts.requireSpace((target.build == "26A434" ? 20 : 12) << 30, at: journal.output)
    let session = try DiskImageSession(image: image, readOnly: true, journal: journal)
    return try session.withAttachment { session in
      let main = try BaseImageStage.mainContainer(session)
      let system = try ImageMounts.mount(
        main.volume(role: "System"), session: session, journal: journal,
        name: "view-system", readOnly: true)
      let data = try ImageMounts.mount(
        main.volume(role: "Data"), session: session, journal: journal,
        name: "view-data", readOnly: true)
      let version = try system.plist("System/Library/CoreServices/SystemVersion.plist")
      guard version["ProductVersion"] as? String == target.version,
        version["ProductBuildVersion"] as? String == target.build
      else {
        throw MisoError.invalid("Execution System version differs from target")
      }
      guard
        let firmlinkText = String(
          data: try SafeFile.read(system.path("usr/share/firmlinks"), limit: 64 << 10),
          encoding: .utf8)
      else {
        throw MisoError.invalid("Invalid firmlink table")
      }
      let bindings = try firmlinks(firmlinkText)
      var originals: [(String, String)] = []
      var compilerTools: [Executable] = []
      let resign = ["25G83", "26A434"].contains(target.build)
      if !resign {
        throw MisoError.unsupported("Base execution view for target build \(target.build)")
      }
      func copy(_ source: URL, _ relative: String, device: dev_t) throws {
        try journal.cancellation.check()
        let info = try FileMetadata.inspect(source)
        let destination = root.appendingPathComponent(relative)
        if device == system.device, bindings[relative] != nil {
          guard info.st_mode & S_IFMT == S_IFDIR,
            [system.device, data.device].contains(info.st_dev)
          else {
            throw MisoError.invalid("Unexpected System firmlink source: \(relative)")
          }
          try SafeFile.makeDirectory(destination)
          guard chmod(destination.path, 0o755) == 0 else {
            throw MisoError.system("Set firmlink stub mode", errno)
          }
          return
        }
        guard info.st_dev == device else {
          throw MisoError.invalid(
            "Execution copy crosses a mount: \(relative) (\(info.st_dev), expected \(device))")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
          try SafeFile.makeDirectory(destination)
          for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
            let child = relative.isEmpty ? name : relative + "/" + name
            if child == "dev" || child == "System/Volumes" { continue }
            try copy(source.appendingPathComponent(name), child, device: device)
          }
          guard chmod(destination.path, info.st_mode & 0o755) == 0 else {
            throw MisoError.system("Set execution directory mode", errno)
          }
        case S_IFREG:
          if info.st_size == 0 {
            try SafeFile.writeNew(Data(), to: destination)
          } else {
            try Artifacts.copy(
              source, to: destination, maximumBytes: UInt64(info.st_size),
              cancellation: journal.cancellation)
          }
          guard chmod(destination.path, info.st_mode & 0o755) == 0 else {
            throw MisoError.system("Set execution file mode", errno)
          }
          let localSignature = resign && requiresLocalSignature(relative)
          let compilerTool = relative.hasPrefix("Library/Developer/CommandLineTools/usr/")
          if localSignature || compilerTool,
            try isExecutable(destination)
          {
            let digest = try SafeFile.sha256(source)
            do {
              try AppleCode.validate(source, scope: .executable)
            } catch {
              throw MisoError.invalid("Execution tool signature rejected at \(relative): \(error)")
            }
            guard try SafeFile.sha256(destination) == digest else {
              throw MisoError.invalid("Execution copy hash mismatch")
            }
            if localSignature {
              originals.append((relative, digest))
            } else {
              try AppleCode.validate(destination, scope: .executable)
              compilerTools.append(
                Executable(path: relative, originalSHA256: digest, executionSHA256: digest))
            }
          }
        case S_IFLNK:
          let link = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
          try createLink(link, at: destination, mode: info.st_mode & 0o755)
        default: throw MisoError.invalid("Unsupported execution source entry")
        }
      }
      for name in try FileManager.default.contentsOfDirectory(atPath: system.root.path).sorted()
      where name != "dev" {
        try copy(system.root.appendingPathComponent(name), name, device: system.device)
      }
      let view = try GuestVolume(root)
      for path in ["dev", "System/Volumes", "System/Volumes/Data", "System/Volumes/Preboot"] {
        let directory = try view.path(path)
        try SafeFile.makeDirectory(directory)
        guard chmod(directory.path, 0o755) == 0 else {
          throw MisoError.system("Set execution mount directory mode", errno)
        }
      }
      try buildLibraryOverlay(data: data, root: root, copy: copy)
      for (path, target) in bindings.sorted(by: { $0.key < $1.key }) {
        if path == "Library" { continue }
        try linkData(path, target: target, root: view)
      }
      if bindings["opt"] == nil { try linkData("opt", target: "opt", root: view) }
      for offset in stride(from: 0, to: originals.count, by: 48) {
        let group = originals[offset..<min(offset + 48, originals.count)]
        try journal.run(
          "remove-execution-signatures",
          NativeCommand(
            .codesign,
            arguments: ["--remove-signature"]
              + group.map { root.appendingPathComponent($0.0).path }, timeout: 180))
        try journal.run(
          "sign-execution-tools",
          NativeCommand(
            .codesign,
            arguments: ["--sign", "-", "--timestamp=none"]
              + group.map { root.appendingPathComponent($0.0).path }, timeout: 180))
      }
      let executableRecords = try originals.map {
        let executable = root.appendingPathComponent($0.0)
        try renewSignedExecutable(executable)
        try AppleCode.validateLocalTool(executable, scope: .executable)
        return Executable(
          path: $0.0, originalSHA256: $0.1,
          executionSHA256: try SafeFile.sha256(executable))
      }
      try SafeFile.writeNew(
        JSON.encode(executableRecords),
        to: journal.output.appendingPathComponent("execution-tools.json"))
      try SafeFile.writeNew(
        JSON.encode(compilerTools),
        to: journal.output.appendingPathComponent("execution-compiler-tools.json"))
      guard chown(root.path, 0, 0) == 0, chmod(root.path, 0o755) == 0 else {
        throw MisoError.system("Finalize execution root", errno)
      }
      try journal.setMetadata("executionTools", value: executableRecords.count)
      try journal.setMetadata("outputSystemModified", value: false)
      return root
    }
  }

  static func requiresLocalSignature(_ relative: String) -> Bool {
    ["bin/", "sbin/", "usr/bin/", "usr/sbin/", "usr/libexec/"].contains {
      relative.hasPrefix($0)
    }
  }

  static func renewSignedExecutable(_ executable: URL) throws {
    let original = try FileMetadata.inspect(executable)
    guard original.st_mode & S_IFMT == S_IFREG, original.st_nlink == 1 else {
      throw MisoError.invalid("Unexpected signed execution file")
    }
    let digest = try SafeFile.sha256(executable)
    let temporary = executable.deletingLastPathComponent()
      .appendingPathComponent(".miso-signed-" + UUID().uuidString)
    try Artifacts.copy(executable, to: temporary, maximumBytes: UInt64(original.st_size))
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard chown(temporary.path, original.st_uid, original.st_gid) == 0,
      chmod(temporary.path, original.st_mode & 0o7777) == 0
    else { throw MisoError.system("Set signed execution copy metadata", errno) }
    let replacement = try FileMetadata.inspect(temporary)
    guard replacement.st_ino != original.st_ino, replacement.st_dev == original.st_dev,
      replacement.st_mode == original.st_mode, replacement.st_uid == original.st_uid,
      replacement.st_gid == original.st_gid, try SafeFile.sha256(temporary) == digest,
      try FileMetadata.inspect(executable).st_ino == original.st_ino
    else { throw MisoError.invalid("Signed execution copy changed") }
    guard rename(temporary.path, executable.path) == 0 else {
      throw MisoError.system("Publish signed execution copy", errno)
    }
  }

  static func createLink(_ target: String, at destination: URL, mode: mode_t = 0o755) throws {
    guard mode & ~0o755 == 0 else { throw MisoError.invalid("Unsafe execution link mode") }
    guard symlink(target, destination.path) == 0 else {
      throw MisoError.system("Create execution link", errno)
    }
    guard lchmod(destination.path, mode) == 0 else {
      throw MisoError.system("Set execution link mode", errno)
    }
  }

  static func firmlinks(_ text: String) throws -> [String: String] {
    var bindings: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
      guard parts.count == 2, parts[0].hasPrefix("/") else {
        throw MisoError.invalid("Invalid firmlink entry")
      }
      let source = try SafeFile.relativePath(String(parts[0].dropFirst()))
      let destination = try SafeFile.relativePath(parts[1])
      guard bindings.updateValue(destination, forKey: source) == nil,
        source != "dev", !source.hasPrefix("dev/"), source != "System/Volumes",
        !source.hasPrefix("System/Volumes/")
      else {
        throw MisoError.invalid("Duplicate or reserved firmlink entry")
      }
    }
    guard !bindings.isEmpty else { throw MisoError.invalid("Empty firmlink table") }
    return bindings
  }

  private static func linkData(_ path: String, target: String, root: GuestVolume) throws {
    let destination = try root.path(path, createParents: true)
    if FileManager.default.fileExists(atPath: destination.path) {
      guard rmdir(destination.path) == 0 else {
        throw MisoError.invalid("Firmlink stub must be empty: \(path)")
      }
    }
    try createLink("/System/Volumes/Data/" + target, at: destination)
  }

  private static func buildLibraryOverlay(
    data: GuestVolume, root: URL, copy: (URL, String, dev_t) throws -> Void
  ) throws {
    let expanded: Set<String> = [
      "Library", "Library/Developer", "Library/Developer/CommandLineTools",
      "Library/Developer/CommandLineTools/usr",
    ]
    let copied: Set<String> = [
      "Library/Developer/CommandLineTools/usr/bin",
      "Library/Developer/CommandLineTools/usr/libexec",
    ]
    func visit(_ path: String) throws {
      let source = try data.path(path, allowLeafLink: true)
      let destination = root.appendingPathComponent(path)
      if copied.contains(path) {
        try copy(source, path, data.device)
      } else if expanded.contains(path) {
        if FileManager.default.fileExists(atPath: destination.path) {
          guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else {
            throw MisoError.invalid("Library overlay conflicts with System contents")
          }
        } else {
          try SafeFile.makeDirectory(destination)
        }
        guard chmod(destination.path, 0o755) == 0 else {
          throw MisoError.system("Set Library overlay mode", errno)
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
          try visit(path + "/" + name)
        }
      } else {
        try createLink("/System/Volumes/Data/" + path, at: destination)
      }
    }
    try visit("Library")
  }

  static func isExecutable(_ url: URL) throws -> Bool {
    let handle = try SafeFile.openRegular(url)
    defer { try? handle.close() }
    let size = try SafeFile.size(handle)
    guard size >= 32 else { return false }
    let header = try handle.readExactly(32)
    if Array(header.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] {
      return Array(header[4..<8]) == [12, 0, 0, 1] && Array(header[12..<16]) == [2, 0, 0, 0]
    }
    guard Array(header.prefix(4)) == [0xca, 0xfe, 0xba, 0xbe] else { return false }
    func integer(_ bytes: Data) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }
    let count = integer(header[4..<8])
    guard count > 0, count <= 64, size >= 8 + count * 20 else {
      throw MisoError.invalid("Invalid universal executable")
    }
    try handle.seek(toOffset: 8)
    let table = try handle.readExactly(Int(count * 20))
    for offset in stride(from: 0, to: table.count, by: 20) {
      if integer(table[offset..<offset + 4]) != 0x0100_000c { continue }
      let start = integer(table[offset + 8..<offset + 12])
      guard start >= 8 + count * 20, start <= size - 32 else {
        throw MisoError.invalid("Invalid executable slice")
      }
      try handle.seek(toOffset: start)
      let slice = try handle.readExactly(32)
      return Array(slice.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe]
        && Array(slice[4..<8]) == [12, 0, 0, 1]
        && Array(slice[12..<16]) == [2, 0, 0, 0]
    }
    return false
  }
}

import CryptoKit
import Darwin
import Foundation

struct GitCheckout {
  struct Entry {
    let path: String
    let mode: UInt32
    let id: Data
    let data: Data

    var isDirectory: Bool { mode == 0o40000 }
    var isLink: Bool { mode == 0o120000 }
  }

  let entries: [Entry]
  let selection: GitRemote.Selection

  init(pack: GitPack, selection: GitRemote.Selection, cancellation: CancellationToken? = nil) throws
  {
    let commitID = try GitRemote.objectID(selection.commitID)
    var id = try GitRemote.objectID(selection.objectID)
    var tags = 0
    while let object = pack.objects[id], object.type == "tag" {
      guard tags < 16 else { throw MisoError.invalid("Excessive Git tag depth") }
      tags += 1
      id = try Self.headerID(object.data, field: "object")
    }
    guard id == commitID, let commit = pack.objects[id], commit.type == "commit" else {
      throw MisoError.invalid("Git reference does not resolve to the selected commit")
    }
    let tree = try Self.headerID(commit.data, field: "tree")
    var entries: [Entry] = []
    var paths = Set<String>()
    var total = 0
    func visit(_ id: Data, parent: String, depth: Int) throws {
      try cancellation?.check()
      guard depth <= 64, let object = pack.objects[id], object.type == "tree" else {
        throw MisoError.invalid("Missing or excessively nested Git tree")
      }
      var cursor = GitPack.Cursor(data: object.data)
      while cursor.offset < object.data.count {
        try cancellation?.check()
        var header = Data()
        while true {
          let byte = try cursor.byte()
          if byte == 0 { break }
          guard header.count < 512 else { throw MisoError.invalid("Excessive Git tree entry name") }
          header.append(byte)
        }
        guard let value = String(data: header, encoding: .utf8),
          let space = value.firstIndex(of: " "),
          let mode = UInt32(value[..<space], radix: 8),
          [0o40000, 0o100644, 0o100755, 0o120000].contains(mode)
        else { throw MisoError.unsupported("Unsupported Git tree entry") }
        let name = String(value[value.index(after: space)...])
        let key = name.precomposedStringWithCanonicalMapping.lowercased()
        guard !name.contains("/"), !name.contains(":"), name.utf8.count <= 255, key != ".git",
          name.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
          })
        else { throw MisoError.invalid("Unsafe Git tree entry name") }
        let path = try SafeFile.relativePath(parent.isEmpty ? name : parent + "/" + name)
        guard path.utf8.count <= 1024,
          paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
          entries.count < 50_000
        else { throw MisoError.invalid("Colliding or excessive Git checkout paths") }
        let childID = try cursor.take(20)
        guard let child = pack.objects[childID], child.type == (mode == 0o40000 ? "tree" : "blob")
        else {
          throw MisoError.invalid("Missing or mismatched Git tree object")
        }
        let data = mode == 0o40000 ? Data() : child.data
        total += data.count
        guard total <= 512 << 20 else { throw MisoError.invalid("Excessive Git checkout data") }
        entries.append(Entry(path: path, mode: mode, id: childID, data: data))
        if mode == 0o40000 { try visit(childID, parent: path, depth: depth + 1) }
      }
    }
    try visit(tree, parent: "", depth: 0)
    if !entries.isEmpty {
      try TarPayload.validate(
        entries.map {
          let link = $0.isLink ? String(data: $0.data, encoding: .utf8) : nil
          guard !$0.isLink || link != nil else {
            throw MisoError.invalid("Invalid Git symbolic link")
          }
          return TarPayload.Entry(
            path: $0.path, kind: $0.isDirectory ? S_IFDIR : ($0.isLink ? S_IFLNK : S_IFREG),
            mode: UInt16($0.mode & 0o777), bytes: Int64($0.data.count), link: link)
        })
    }
    self.entries = entries
    self.selection = selection
  }

  static func headerID(_ data: Data, field: String) throws -> Data {
    let prefix = Data((field + " ").utf8)
    guard data.starts(with: prefix), data.count > prefix.count + 40,
      data[data.startIndex + prefix.count + 40] == 10,
      let value = String(data: data.dropFirst(prefix.count).prefix(40), encoding: .utf8)
    else { throw MisoError.invalid("Invalid Git \(field) header") }
    return try GitRemote.objectID(value)
  }

  func write(to output: URL, pack: GitPack, origin: URL, cancellation: CancellationToken? = nil)
    throws
  {
    try SafeFile.makeDirectory(output, mode: 0o755)
    let volume = try GuestVolume(output)
    for entry in entries where entry.isDirectory {
      try cancellation?.check()
      try SafeFile.makeDirectory(volume.path(entry.path, createParents: true), mode: 0o755)
    }
    for entry in entries where !entry.isDirectory && !entry.isLink {
      try cancellation?.check()
      let handle = try SafeFile.create(volume.path(entry.path))
      defer { try? handle.close() }
      try handle.write(contentsOf: entry.data)
      guard fchmod(handle.fileDescriptor, mode_t(entry.mode & 0o777)) == 0 else {
        throw MisoError.system("Set Git checkout mode", errno)
      }
    }
    for entry in entries where entry.isLink {
      try cancellation?.check()
      let path = try volume.path(entry.path)
      guard let link = String(data: entry.data, encoding: .utf8), symlink(link, path.path) == 0
      else {
        throw MisoError.system("Create Git checkout link", errno)
      }
    }
    let hash = SafeFile.hex(pack.bytes.suffix(20))
    func write(_ path: String, _ data: Data) throws {
      try SafeFile.writeNew(data, to: volume.path(".git/" + path, createParents: true))
    }
    try write("objects/pack/pack-\(hash).pack", pack.bytes)
    try write("objects/pack/pack-\(hash).idx", pack.index)
    try write("HEAD", Data((selection.commitID + "\n").utf8))
    try write("shallow", Data((selection.commitID + "\n").utf8))
    try write(
      "config",
      Data(
        """
        [core]
        \trepositoryformatversion = 0
        \tbare = false
        \tfilemode = true
        \tlogallrefupdates = false
        [remote "origin"]
        \turl = \(origin.absoluteString)
        \tfetch = +refs/heads/*:refs/remotes/origin/*

        """.utf8))
    if selection.reference.hasPrefix("refs/") {
      try GitRemote.validateReference(selection.reference)
      try write(selection.reference, Data((selection.objectID + "\n").utf8))
    } else {
      try write("refs/remotes/origin/HEAD", Data((selection.commitID + "\n").utf8))
    }
    try write("index", index)
  }

  var index: Data {
    let files = entries.filter { !$0.isDirectory }.sorted {
      $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
    }
    var output = Data("DIRC".utf8)
    output.appendGitInteger(2)
    output.appendGitInteger(UInt32(files.count))
    for file in files {
      let start = output.count
      for value: UInt32 in [0, 0, 0, 0, 0, 0, file.mode, 0, 0, UInt32(file.data.count)] {
        output.appendGitInteger(value)
      }
      output.append(file.id)
      let path = Data(file.path.utf8)
      let length = min(4095, path.count)
      output.append(UInt8(length >> 8))
      output.append(UInt8(length & 255))
      output.append(path)
      output.append(contentsOf: repeatElement(UInt8(0), count: 8 - (output.count - start) % 8))
    }
    output.append(contentsOf: Insecure.SHA1.hash(data: output))
    return output
  }
}

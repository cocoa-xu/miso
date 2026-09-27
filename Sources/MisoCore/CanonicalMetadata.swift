import AppleArchive
import Foundation
import System

enum CanonicalMetadata {
  static func extract(_ source: URL, to output: URL, cancellation: CancellationToken? = nil) throws
  {
    let input = try SafeFile.openRegular(source)
    defer { try? input.close() }
    guard
      let file = ArchiveByteStream.fileStream(
        fd: FileDescriptor(rawValue: input.fileDescriptor), automaticClose: false),
      let archive = ArchiveStream.decodeStream(readingFrom: file, threadCount: 2)
    else {
      throw MisoError.invalid("Cannot decode canonical archive")
    }
    defer {
      try? archive.close()
      try? file.close()
    }
    try SafeFile.makeDirectory(output)
    var seen = Set<String>()
    var total: UInt64 = 0
    while let header = try archive.readHeader() {
      try cancellation?.check()
      guard seen.count < 3, case .string(_, let path)? = header.field(forKey: .init("PAT")),
        case .uint(_, let type)? = header.field(forKey: .init("TYP"))
      else {
        throw MisoError.invalid("Invalid canonical archive entry")
      }
      let name = path.isEmpty ? "." : path
      guard seen.insert(name).inserted else {
        throw MisoError.invalid("Duplicate canonical archive entry")
      }
      if name == "." {
        guard type == UInt64(ArchiveHeader.EntryType.directory.rawValue),
          header.field(forKey: .init("DAT")) == nil
        else {
          throw MisoError.invalid("Invalid canonical root directory")
        }
        continue
      }
      guard ["mtree.txt", "digest.db"].contains(name),
        type == UInt64(ArchiveHeader.EntryType.regularFile.rawValue),
        case .blob(_, let size, let offset)? = header.field(forKey: .init("DAT")),
        offset == 0, size > 0, size <= 512 << 20, size <= (768 << 20) - total
      else {
        throw MisoError.invalid("Unexpected canonical archive payload")
      }
      let destination = try SafeFile.create(output.appendingPathComponent(name))
      defer { try? destination.close() }
      let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
      defer { buffer.deallocate() }
      var remaining = size
      while remaining > 0 {
        try cancellation?.check()
        let count = Int(min(remaining, UInt64(buffer.count)))
        let part = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
        try archive.readBlob(key: .init("DAT"), into: part)
        try autoreleasepool {
          try destination.write(
            contentsOf: Data(bytesNoCopy: part.baseAddress!, count: count, deallocator: .none))
        }
        remaining -= UInt64(count)
      }
      try destination.synchronize()
      total += size
    }
    guard seen == [".", "digest.db", "mtree.txt"] else {
      throw MisoError.invalid("Missing canonical archive entries")
    }
    try archive.close()
  }

  static func timestampRemap(_ mtree: URL) throws -> [String: UInt64] {
    let input = try SafeFile.openRegular(mtree)
    defer { try? input.close() }
    let prefix = try input.read(upToCount: 64 << 10) ?? Data()
    let lines = String(decoding: prefix, as: UTF8.self).split(
      separator: "\n", omittingEmptySubsequences: false
    ).prefix(100)
    let pattern = try NSRegularExpression(pattern: #"^\.\s+.*\btime=(\d+)\.(\d{9})\b"#)
    for value in lines {
      let line = String(value)
      guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let secondsRange = Range(match.range(at: 1), in: line),
        let fractionRange = Range(match.range(at: 2), in: line),
        let seconds = UInt64(line[secondsRange]), let fraction = UInt64(line[fractionRange])
      else { continue }
      let (whole, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
      let (nanoseconds, addOverflow) = whole.addingReportingOverflow(fraction)
      guard !multiplyOverflow, !addOverflow else {
        throw MisoError.invalid("Canonical timestamp overflow")
      }
      return Dictionary(
        uniqueKeysWithValues: ["ACCESS", "BIRTH", "CHANGE", "DATEADDED", "MODIFICATION"].map {
          ($0, nanoseconds)
        })
    }
    throw MisoError.invalid("Missing canonical root timestamp")
  }
}

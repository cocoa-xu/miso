import Darwin
import Foundation
import Testing

@testable import MisoCore

@Test func streamingHashHasBoundedMemory() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let url = directory.url.appendingPathComponent("sparse.img")
  let handle = try SafeFile.create(url)
  try handle.truncate(atOffset: 4 << 30)
  try handle.close()
  var before = rusage()
  var after = rusage()
  #expect(getrusage(RUSAGE_SELF, &before) == 0)
  let digest = try SafeFile.sha256(url)
  #expect(getrusage(RUSAGE_SELF, &after) == 0)
  #expect(digest == "8479e43911dc45e89f934fe48d01297e16f51d17aa561d4d1c216b1ae0fcddca")
  #expect(after.ru_maxrss - before.ru_maxrss < 256 << 20)
}

@Test func streamingCryptexHashHasBoundedMemory() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let url = directory.url.appendingPathComponent("sparse.img")
  let handle = try SafeFile.create(url)
  try handle.truncate(atOffset: 4 << 30)
  try handle.close()
  var before = rusage()
  var after = rusage()
  #expect(getrusage(RUSAGE_SELF, &before) == 0)
  let digest = try BootTree.hash384(url)
  #expect(getrusage(RUSAGE_SELF, &after) == 0)
  #expect(
    SafeFile.hex(digest)
      == "92484b752d7078365893d7109ce8cea17f6a4819f5cd0d7b57616f51b48fe704782a007699f95f6dabbd6fd1da927f73"
  )
  #expect(after.ru_maxrss - before.ru_maxrss < 256 << 20)
  let cancellation = try CancellationToken()
  cancellation.cancel()
  #expect(throws: CancellationError.self) {
    try BootTree.hash384(url, cancellation: cancellation)
  }
}

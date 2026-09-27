import CMiso
import CryptoKit
import Foundation
import Testing

@testable import MisoCore

private struct PackFixture {
  var payload = Data()
  var count: UInt32 = 0

  mutating func append(_ type: UInt8, _ data: Data, base: Data = Data()) throws -> Int {
    let offset = 12 + payload.count
    var size = data.count
    var byte = (type << 4) | UInt8(size & 15)
    size >>= 4
    while size > 0 {
      payload.append(byte | 128)
      byte = UInt8(size & 127)
      size >>= 7
    }
    payload.append(byte)
    payload.append(base)
    var compressedSize = compressBound(UInt(data.count))
    var compressed = Data(count: Int(compressedSize))
    let status = compressed.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        compress2(
          destination.bindMemory(to: UInt8.self).baseAddress!, &compressedSize,
          source.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), Z_BEST_SPEED)
      }
    }
    guard status == Z_OK else { throw MisoError.invalid("Compress Git test fixture") }
    payload.append(compressed.prefix(Int(compressedSize)))
    count += 1
    return offset
  }

  var data: Data {
    var output = Data("PACK".utf8)
    output.appendGitInteger(2)
    output.appendGitInteger(count)
    output.append(payload)
    return signed(output)
  }

  static func id(_ data: Data, type: String = "blob") -> Data {
    Data(Insecure.SHA1.hash(data: Data("\(type) \(data.count)\0".utf8) + data))
  }

  static func distance(_ value: Int) -> Data {
    var value = value
    var bytes = [UInt8(value & 127)]
    value >>= 7
    while value > 0 {
      value -= 1
      bytes.append(UInt8(value & 127) | 128)
      value >>= 7
    }
    return Data(bytes.reversed())
  }
}

private func signed(_ data: Data) -> Data {
  data + Data(Insecure.SHA1.hash(data: data))
}

@Test func gitPackRawObjectsAndSlices() throws {
  var fixture = PackFixture()
  let inputs = [Data(), Data("hello\n".utf8), Data(repeating: 42, count: 32_768)]
  for data in inputs { _ = try fixture.append(3, data) }
  let padded = Data([0]) + fixture.data
  let pack = try GitPack(padded.dropFirst())
  #expect(pack.objects.count == 3)
  for data in inputs {
    let object = try #require(pack.objects[PackFixture.id(data)])
    #expect(object.type == "blob")
    #expect(object.data == data)
    #expect(object.deltaDepth == 0)
  }
}

@Test func gitPackOffsetAndForwardReferenceDeltas() throws {
  let base = Data("hello world\n".utf8)
  let delta = Data([12, 12, 0x90, 6, 6]) + Data("there\n".utf8)
  let result = Data("hello there\n".utf8)
  var offsets = PackFixture()
  let offset = try offsets.append(3, base)
  _ = try offsets.append(3, Data(repeating: 17, count: 4096))
  let distance = 12 + offsets.payload.count - offset
  _ = try offsets.append(6, delta, base: PackFixture.distance(distance))
  var references = PackFixture()
  _ = try references.append(7, delta, base: PackFixture.id(base))
  _ = try references.append(3, base)
  for fixture in [offsets, references] {
    let object = try #require(GitPack(fixture.data).objects[PackFixture.id(result)])
    #expect(object.data == result)
    #expect(object.deltaDepth == 1)
  }
  #expect(try GitPack.applyDelta(delta, to: (Data([0]) + base).dropFirst()) == result)
}

@Test(arguments: [false, true])
func gitPackEnforcesActualDeltaDepth(_ reversed: Bool) throws {
  for depth in [64, 65] {
    var fixture = PackFixture()
    if !reversed { _ = try fixture.append(3, Data([0])) }
    let levels = reversed ? Array((1...depth).reversed()) : Array(1...depth)
    for level in levels {
      _ = try fixture.append(
        7, Data([1, 1, 1, UInt8(level)]), base: PackFixture.id(Data([UInt8(level - 1)])))
    }
    if reversed { _ = try fixture.append(3, Data([0])) }
    if depth == 64 {
      let object = try #require(GitPack(fixture.data).objects[PackFixture.id(Data([64]))])
      #expect(object.deltaDepth == 64)
    } else {
      #expect(throws: MisoError.self) { try GitPack(fixture.data) }
    }
  }
}

@Test func gitPackRejectsInvalidObjects() throws {
  var valid = PackFixture()
  _ = try valid.append(3, Data([1, 2, 3]))
  var checksum = valid.data
  checksum[checksum.count - 1] ^= 1
  var version = Data(valid.data.dropLast(20))
  version[7] = 3
  var count = Data(valid.data.dropLast(20))
  count[11] = 2
  var invalidType = PackFixture()
  _ = try invalidType.append(5, Data())
  var missing = PackFixture()
  _ = try missing.append(7, Data([1, 1, 1, 2]), base: PackFixture.id(Data([1])))
  var duplicate = valid
  _ = try duplicate.append(3, Data([1, 2, 3]))
  var offset = PackFixture()
  _ = try offset.append(6, Data([0, 0]), base: Data([0]))
  var size = Data(valid.data.dropLast(20))
  size[12] = 0x34
  var compressed = Data(valid.data.dropLast(20))
  compressed[compressed.count - 1] ^= 1
  for bytes in [
    Data(), checksum, signed(version), signed(count), invalidType.data, missing.data,
    duplicate.data, offset.data, signed(size), signed(compressed),
    signed(Data(valid.data.dropLast(20)) + Data([0])),
    signed(Data(valid.data.dropLast(21))),
  ] {
    #expect(throws: MisoError.self) { try GitPack(bytes) }
  }
}

@Test(arguments: [
  Data(), Data([2, 0]), Data([1, 1, 0]), Data([1, 1, 2, 1, 2]), Data([1, 1, 1]),
  Data([1, 1, 0x91, 2, 1]), Data([1, 1, 0x90, 2]), Data([1, 1, 0x80]),
  Data([1, 2, 1, 1]), Data([1, 0xff, 0xff, 0xff, 0x7f]),
])
func gitDeltaRejectsMalformedCommands(_ delta: Data) {
  #expect(throws: MisoError.self) { try GitPack.applyDelta(delta, to: Data([1])) }
}

@Test func gitDeltaDefaultCopySize() throws {
  let base = Data(repeating: 42, count: 65_536)
  let delta = Data([0x80, 0x80, 4, 0x80, 0x80, 4, 0x80])
  #expect(try GitPack.applyDelta(delta, to: base) == base)
}

@Test func gitPackCancellation() throws {
  var fixture = PackFixture()
  _ = try fixture.append(3, Data([1]))
  let token = try CancellationToken()
  token.cancel()
  #expect(throws: CancellationError.self) { try GitPack(fixture.data, cancellation: token) }
}

@Test func gitPackIndexPassesIndependentGitVerification() throws {
  var fixture = PackFixture()
  let base = Data("hello world\n".utf8)
  _ = try fixture.append(3, base)
  _ = try fixture.append(
    7, Data([12, 12, 0x90, 6, 6]) + Data("there\n".utf8), base: PackFixture.id(base))
  _ = try fixture.append(2, Data())
  let pack = try GitPack(fixture.data)
  let index = pack.index
  #expect(index.suffix(20) == Data(Insecure.SHA1.hash(data: index.dropLast(20))))
  #expect(try index.integer(at: 1028, as: UInt32.self, bigEndian: true) == 3)
  let temporary = try TemporaryDirectory()
  defer { temporary.remove() }
  try SafeFile.writeNew(pack.bytes, to: temporary.url.appendingPathComponent("fixture.pack"))
  let indexFile = temporary.url.appendingPathComponent("fixture.idx")
  try SafeFile.writeNew(index, to: indexFile)
  let out = try SafeFile.create(temporary.url.appendingPathComponent("stdout"))
  let err = try SafeFile.create(temporary.url.appendingPathComponent("stderr"))
  defer {
    try? out.close()
    try? err.close()
  }
  let result = try NativeProcess.run(
    NativeCommand(
      "/usr/bin/git", arguments: ["verify-pack", indexFile.path], timeout: 15,
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]),
    stdout: out, stderr: err)
  #expect(result.succeeded)
}

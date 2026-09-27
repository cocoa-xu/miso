import CryptoKit
import Darwin
import Foundation

enum Image4Trust {
  enum Decoder: String {
    case firmware = "kImg4DecodeSecureBootRsa4kSha384DDI"
    case globalFirmware = "kImg4DecodeSecureBootRsa4kSha384X86"
    case globalCryptex = "kImg4DecodeSecureBootRsa4kSha384DDIGlobal"
    case recoveryPolicy = "kImg4DecodeLocalPolicyRsa4kSha384"
    case virtualPolicy = "kImg4DecodeLocalPolicyEc384Sha384Hacktivate"
  }

  typealias GetData =
    @convention(c) (
      UnsafeRawPointer?, UInt32, UnsafeMutablePointer<UnsafeRawPointer?>?,
      UnsafeMutablePointer<UInt32>?
    ) -> Int32
  typealias Callback =
    @convention(c) (UInt32, UnsafeRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Int32

  final class Context {
    let digest: Data
    let getData: GetData
    var checkedDigest = false
    var nonce: Data?
    var checkedNonce = false

    init(digest: Data, getData: @escaping GetData) {
      self.digest = digest
      self.getData = getData
    }
  }

  static func fourCC(_ value: String) -> UInt32 {
    value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  static func fields(_ image: Data) throws -> [DER.Node] {
    let values = try DER.nodes(DER.one(image, tag: 0x30).content)
    guard [3, 4].contains(values.count), values[0].tag == 0x16,
      values[0].content == Data("IMG4".utf8), values[2].tag == 0xA0,
      values.count != 4 || values[3].tag == 0xA1
    else { throw MisoError.invalid("Invalid signed Image4 shape") }
    _ = try Image4.payloadFields(values[1].encoded)
    _ = try Image4.manifestProperties(values[2].content)
    return values
  }

  @discardableResult
  static func authenticate(_ image: Data, type: String, decoder: Decoder, nonce: Bool = false)
    throws -> Data?
  {
    _ = try APFSPrivate.requireHost()
    let measurement = try evaluate(image, type: type, decoder: decoder, nonce: nonce, trusted: true)
    let fields = try fields(image)
    let root = try DER.one(image)
    let payloadOffset = root.encoded.count - root.content.count + fields[0].encoded.count
    var changed = image
    changed[payloadOffset + fields[1].encoded.count - 1] ^= 1
    _ = try evaluate(changed, type: type, decoder: decoder, nonce: nonce, trusted: false)
    let manifest = try DER.nodes(DER.one(fields[2].content, tag: 0x30).content)
    guard manifest.count == 5, manifest[3].tag == 4, !manifest[3].content.isEmpty,
      let range = image.range(of: manifest[3].content)
    else { throw MisoError.invalid("Missing Image4 signature") }
    changed = image
    changed[range.lowerBound] ^= 1
    _ = try evaluate(changed, type: type, decoder: decoder, nonce: nonce, trusted: false)
    if nonce {
      guard fields.count == 4 else { throw MisoError.invalid("Missing Image4 restore nonce") }
      let restore = try DER.nodes(DER.one(fields[3].content, tag: 0x30).content)
      guard restore.count == 2, restore[0].content == Data("IM4R".utf8),
        let value = try Image4.properties(restore[1].encoded)["BNCN"]
      else { throw MisoError.invalid("Invalid Image4 restore nonce") }
      let bytes = try DER.one(value, tag: 4).content
      guard bytes.count == 8, let range = image.range(of: bytes, options: .backwards) else {
        throw MisoError.invalid("Invalid Image4 boot nonce size")
      }
      changed = image
      changed[range.lowerBound] ^= 1
      _ = try evaluate(changed, type: type, decoder: decoder, nonce: true, trusted: false)
    }
    return measurement
  }

  static func evaluate(
    _ image: Data, type expectedType: String, decoder: Decoder, nonce: Bool, trusted: Bool
  ) throws -> Data? {
    guard image.count <= 128 << 20, expectedType.utf8.count == 4,
      let library = dlopen("/usr/lib/libamsupport.dylib", RTLD_NOW)
    else { throw MisoError.invalid("Invalid Image4 input or unavailable host decoder") }
    defer { dlclose(library) }
    typealias Initialize =
      @convention(c) (UnsafeRawPointer?, Int, UnsafeMutableRawPointer?) -> Int32
    typealias PayloadType =
      @convention(c) (UnsafeRawPointer?, UnsafeMutablePointer<UInt32>?) -> Int32
    typealias Trust =
      @convention(c) (
        UInt32, UnsafeRawPointer?, Callback?, UnsafeRawPointer?, UnsafeMutableRawPointer?
      ) -> Int32
    typealias Measurement =
      @convention(c) (
        UnsafeRawPointer?, Callback?, UnsafeRawPointer?, UnsafeMutableRawPointer?, Int
      ) -> Int32
    typealias RestoreData =
      @convention(c) (
        UnsafeRawPointer?, UInt32, UnsafeMutablePointer<UnsafeRawPointer?>?,
        UnsafeMutablePointer<Int>?
      ) -> Int32
    guard let initializeSymbol = dlsym(library, "Img4DecodeInit"),
      let payloadSymbol = dlsym(library, "Img4DecodeGetPayloadType"),
      let trustSymbol = dlsym(library, "Img4DecodePerformTrustEvaluation"),
      let measurementSymbol = dlsym(library, "Img4DecodeCopyManifestTrustedBootPolicyMeasurement"),
      let dataSymbol = dlsym(library, "Img4DecodeGetPropertyData"),
      let implementation = dlsym(library, decoder.rawValue)
    else { throw MisoError.unsupported("host Image4 functions") }
    let initialize = unsafeBitCast(initializeSymbol, to: Initialize.self)
    let payloadType = unsafeBitCast(payloadSymbol, to: PayloadType.self)
    let trust = unsafeBitCast(trustSymbol, to: Trust.self)
    let payload = try fields(image)[1].encoded
    let validation = Context(
      digest: Data(SHA384.hash(data: payload)), getData: unsafeBitCast(dataSymbol, to: GetData.self)
    )
    let collect: Callback = { tag, property, section, opaque in
      guard let opaque else { return -1 }
      let validation = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
      if (tag == Image4Trust.fourCC("DGST") && section == 1)
        || (tag == Image4Trust.fourCC("BNCH") && section == 0 && validation.nonce != nil)
      {
        var bytes: UnsafeRawPointer?
        var length: UInt32 = 0
        guard validation.getData(property, tag, &bytes, &length) == 0, let bytes, length <= 64
        else { return -1 }
        let value = Data(bytes: bytes, count: Int(length))
        if tag == Image4Trust.fourCC("BNCH") {
          validation.checkedNonce = true
          return value == validation.nonce ? 0 : -1
        }
        validation.checkedDigest = true
        return value == validation.digest ? 0 : -1
      }
      return 0
    }
    let context = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    defer { context.deallocate() }
    context.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
    return try image.withUnsafeBytes { bytes in
      guard initialize(bytes.baseAddress, image.count, context) == 0 else {
        throw MisoError.invalid("Apple Image4 initialization failed")
      }
      if nonce {
        guard let symbol = dlsym(library, "Img4DecodeGetRestoreInfoData") else {
          throw MisoError.unsupported("Image4 restore nonce getter")
        }
        let getRestore = unsafeBitCast(symbol, to: RestoreData.self)
        var pointer: UnsafeRawPointer?
        var length = 0
        guard getRestore(context, fourCC("BNCN"), &pointer, &length) == 0, length == 8, let pointer
        else {
          throw MisoError.invalid("Expected an eight-byte boot nonce")
        }
        validation.nonce = Data(SHA384.hash(data: Data(bytes: pointer, count: length))).prefix(32)
      }
      var type: UInt32 = 0
      guard payloadType(context, &type) == 0, type == fourCC(expectedType) else {
        throw MisoError.invalid("Apple Image4 payload type mismatch")
      }
      let status = trust(
        type, context, collect, implementation, Unmanaged.passUnretained(validation).toOpaque())
      guard (status == 0) == trusted, !trusted || validation.checkedDigest,
        !trusted || !nonce || validation.checkedNonce
      else {
        throw MisoError.invalid("Apple Image4 authentication or negative control failed: \(status)")
      }
      guard trusted, expectedType == "lpol" else { return nil }
      let measure = unsafeBitCast(measurementSymbol, to: Measurement.self)
      let accept: Callback = { _, _, _, _ in 0 }
      var measurement = Data(count: 48)
      let measured = measurement.withUnsafeMutableBytes {
        measure(context, accept, implementation, $0.baseAddress, $0.count)
      }
      guard measured == 0 else { throw MisoError.invalid("Apple boot policy measurement failed") }
      return measurement
    }
  }
}

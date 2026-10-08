import Darwin
import Foundation
import MachO

enum MetalAssetRegistration {
  static let type = "com.apple.MobileAsset.MetalToolchain"
  static let directory = "System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain"
  static let catalogPath = directory + "/com_apple_MobileAsset_MetalToolchain.xml"

  struct Catalog {
    let identifier: String
    let attributes: [String: Any]
    let properties: [String: Any]
    var assetPath: String { directory + "/" + identifier + ".asset" }
  }

  static func catalog(_ payload: Data, build: String) throws -> Catalog {
    _ = try AppleAssetCatalog.select(payload, assetType: type, build: build)
    guard let source = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let assets = source["Assets"] as? [[String: Any]], assets.count == 1,
      let transformations = source["Transformations"] as? [String: String],
      let set = source["AssetSetId"] as? String
    else { throw MisoError.invalid("Incomplete Metal asset catalog") }
    var attributes = assets[0]
    for (key, kind) in transformations where attributes[key] != nil {
      guard kind == "data", let value = attributes[key] as? String,
        let bytes = Data(base64Encoded: value)
      else { throw MisoError.invalid("Invalid Metal catalog transformation: \(key)") }
      attributes[key] = bytes
    }
    var properties: [String: Any] = [
      "AssetType": type, "Assets": [attributes], "CachedAssetSetId": set,
      "catalogInfo": ["isLiveServer": true],
      "DownloadedFromLive": "https://gdmf.apple.com/v2/assets", "lastTimeChecked": Date(),
    ]
    if let posting = source["PostingDate"] as? String,
      let date = ISO8601DateFormatter().date(from: posting + "T00:00:00Z")
    {
      properties["postedDate"] = date
    }
    return Catalog(
      identifier: try identifier(attributes), attributes: attributes, properties: properties)
  }

  static func identifier(_ attributes: [String: Any]) throws -> String {
    let library = try NativeLibrary(
      "/System/Library/PrivateFrameworks/MobileAsset.framework/MobileAsset")
    defer { withExtendedLifetime(library) {} }
    typealias Identifier = @convention(c) (NSString, NSDictionary) -> Unmanaged<AnyObject>?
    let function = unsafeBitCast(try identifierSymbol(library), to: Identifier.self)
    guard
      let value = function(type as NSString, attributes as NSDictionary)?.takeUnretainedValue()
        as? String,
      value.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil
    else { throw MisoError.invalid("MobileAsset returned an invalid Metal asset identifier") }
    return value
  }

  private static func identifierSymbol(_ library: NativeLibrary) throws -> UnsafeRawPointer {
    // MobileAsset keeps its identifier routine as a local symbol, unavailable through dlsym.
    let name = "_getAssetIdFromDict"
    for index in 0..<_dyld_image_count() {
      guard let imageName = _dyld_get_image_name(index),
        String(cString: imageName) == library.path
          || String(cString: imageName)
            == "/System/Library/PrivateFrameworks/MobileAsset.framework/Versions/A/MobileAsset",
        let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64
      else { continue }
      let base = UnsafeRawPointer(header)
      let image = base.load(as: mach_header_64.self)
      let slide = _dyld_get_image_vmaddr_slide(index)
      var cursor = base.advanced(by: MemoryLayout<mach_header_64>.size)
      let end = cursor.advanced(by: Int(image.sizeofcmds))
      var link: segment_command_64?
      var symbols: symtab_command?
      var executable: Range<UInt64>?
      for _ in 0..<image.ncmds {
        guard cursor + MemoryLayout<load_command>.size <= end else { break }
        let command = cursor.load(as: load_command.self)
        guard command.cmdsize >= MemoryLayout<load_command>.size,
          cursor + Int(command.cmdsize) <= end
        else { break }
        if command.cmd == LC_SEGMENT_64,
          command.cmdsize >= MemoryLayout<segment_command_64>.size
        {
          let segment = cursor.load(as: segment_command_64.self)
          let segmentName = cursor.advanced(by: 8).assumingMemoryBound(to: CChar.self)
          if String(cString: segmentName) == "__LINKEDIT" { link = segment }
          if String(cString: segmentName) == "__TEXT" {
            executable = segment.vmaddr..<(segment.vmaddr + segment.vmsize)
          }
        }
        if command.cmd == LC_SYMTAB, command.cmdsize >= MemoryLayout<symtab_command>.size {
          symbols = cursor.load(as: symtab_command.self)
        }
        cursor = cursor.advanced(by: Int(command.cmdsize))
      }
      guard let link, let symbols, let executable,
        UInt64(symbols.symoff) >= link.fileoff, UInt64(symbols.stroff) >= link.fileoff,
        UInt64(symbols.symoff) + UInt64(symbols.nsyms) * UInt64(MemoryLayout<nlist_64>.size)
          <= link.fileoff + link.filesize,
        UInt64(symbols.stroff) + UInt64(symbols.strsize) <= link.fileoff + link.filesize
      else { continue }
      let linkBase = Int(link.vmaddr) + slide - Int(link.fileoff)
      let table = UnsafePointer<nlist_64>(bitPattern: linkBase + Int(symbols.symoff))!
      let strings = UnsafePointer<CChar>(bitPattern: linkBase + Int(symbols.stroff))!
      for offset in 0..<Int(symbols.nsyms) {
        let symbol = table[offset]
        guard symbol.n_type & UInt8(N_STAB) == 0,
          symbol.n_type & UInt8(N_TYPE) == UInt8(N_SECT), executable.contains(symbol.n_value),
          UInt64(symbol.n_un.n_strx) + UInt64(name.utf8.count) + 1 <= UInt64(symbols.strsize)
        else { continue }
        if name.withCString({
          strncmp(strings.advanced(by: Int(symbol.n_un.n_strx)), $0, name.utf8.count + 1) == 0
        }) {
          return UnsafeRawPointer(bitPattern: Int(symbol.n_value) + slide)!
        }
      }
    }
    throw MisoError.unsupported(
      "Missing required symbol getAssetIdFromDict in \(library.path) on macOS "
        + "\(library.host.productVersion) (\(library.host.productBuild))")
  }
}

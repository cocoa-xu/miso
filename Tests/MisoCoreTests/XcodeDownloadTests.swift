import Foundation
import Testing

@testable import MisoCore

private let releases = Data(
  """
  [
    {"version":{"number":"4.2","build":"4D199","release":{"beta":7}}},
    {"version":{"number":"27.0","build":"27A266a","release":{"rc":1}},
     "links":{"download":{"url":"https://download.developer.apple.com/Developer_Tools/Xcode_27_Release_Candidate/Xcode_27_Release_Candidate.xip","architectures":["arm64"]}}},
    {"version":{"number":"27.0","build":"27A266a","release":{"release":true}},
     "links":{"download":{"url":"https://download.developer.apple.com/Developer_Tools/Xcode_27/Xcode_27.xip","architectures":["arm64"]}}},
    {"version":{"number":"27.1","build":"27A9275","release":{"rc":1}},
     "links":{"download":{"url":"https://download.developer.apple.com/Developer_Tools/Xcode_27.1_Release_Candidate/Xcode_27.1_Release_Candidate.xip","architectures":["arm64"]}}}
  ]
  """.utf8)

@Test func xcodeMirrorUsesTheExactAppleFilenameForTheSelectedBuild() throws {
  var configuration = XcodeConfiguration()
  #expect(
    try XcodeDownload.filename(catalog: releases, configuration: configuration) == "Xcode_27.xip")
  configuration.version = "27.1"
  configuration.build = "27A9275"
  let filename = try XcodeDownload.filename(catalog: releases, configuration: configuration)
  #expect(filename == "Xcode_27.1_Release_Candidate.xip")
  for base in ["https://mirror.example/private/xcode", "https://mirror.example/private/xcode/"] {
    #expect(
      try XcodeDownload.source(baseURL: base, filename: filename).absoluteString
        == "https://mirror.example/private/xcode/Xcode_27.1_Release_Candidate.xip")
  }
  configuration.build = "27A9269"
  #expect(throws: MisoError.self) {
    try XcodeDownload.filename(catalog: releases, configuration: configuration)
  }
}

@Test func xcodeMirrorRejectsFilenameOverridesAndUntrustedCatalogLinks() throws {
  for source in [
    "http://mirror.example/xcode", "https://user:secret@mirror.example/xcode",
    "https://mirror.example/xcode?file=custom.xip", "https://mirror.example/custom.xip",
    "https://mirror.example/xcode\nINJECT=value",
  ] {
    #expect(throws: MisoError.self) {
      try XcodeDownload.source(baseURL: source, filename: "Xcode_27.xip")
    }
  }
  #expect(throws: MisoError.self) {
    try XcodeDownload.source(baseURL: "https://mirror.example/xcode", filename: "../other.xip")
  }
  let altered = Data(
    String(decoding: releases, as: UTF8.self)
      .replacingOccurrences(of: "download.developer.apple.com", with: "other.example").utf8)
  #expect(throws: MisoError.self) {
    try XcodeDownload.filename(catalog: altered, configuration: .init())
  }
}

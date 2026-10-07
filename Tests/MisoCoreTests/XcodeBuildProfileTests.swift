import Foundation
import Testing

@testable import MisoCore

@Test func xcodeYAMLProfileComposesIndependentOptionsAndRejectsTypos() throws {
  let directory = try TemporaryDirectory()
  defer { directory.remove() }
  let path = directory.url.appendingPathComponent("profile.yaml")
  try SafeFile.writeNew(
    Data("platforms: [iOS, watchOS]\ntrimIntel: true\nsparsify: false\n".utf8), to: path)
  let profile = try XcodeBuildProfile.read(path)
  #expect(profile.platforms == [.iOS, .watchOS] && profile.trimIntel)
  #expect(profile.transparentCompression && profile.cleanup && !profile.sparsify)
  for invalid in [
    "compress: true", "trimIntel: true\ntrimIntel: false", "platforms: [iOS, iOS]",
    "trimIntel: maybe", "platforms: [Linux]",
  ] {
    try SafeFile.replace(Data(invalid.utf8), at: path)
    #expect(throws: (any Error).self) { try XcodeBuildProfile.read(path) }
  }
  try SafeFile.replace(Data("platforms: []\n".utf8), at: path)
  #expect(try XcodeBuildProfile.read(path).platforms.isEmpty)
}

@Test func xcodeProfilesRequireMatchingPlatformsAndPreserveOldConfigurations() throws {
  var configuration = XcodeConfiguration()
  configuration.profile = .slim
  #expect(throws: MisoError.self) { try configuration.validate() }
  configuration.platforms = [.iOS, .watchOS]
  try configuration.validate()
  #expect(
    try JSONDecoder().decode(XcodeConfiguration.self, from: JSON.encode(configuration))
      == configuration)
  let original = XcodeConfiguration()
  #expect(
    try JSONDecoder().decode(XcodeConfiguration.self, from: JSON.encode(original)).profile == nil)
}


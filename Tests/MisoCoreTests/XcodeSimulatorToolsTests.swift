import Foundation
import Testing

@testable import MisoCore

@Test func simulatorToolFormulaRequiresReviewedBottleAndPrerequisites() throws {
  let formula = """
    class Applesimutils < Formula
      url 'https://github.com/wix/AppleSimulatorUtils/releases/download/0.9.12/AppleSimulatorUtils-0.9.12.tar.gz'
      bottle do
        root_url 'https://github.com/wix/AppleSimulatorUtils/releases/download/0.9.12'
        sha256 arm64_big_sur: "\(String(repeating: "a", count: 64))"
      end
      depends_on xcode: ["8.0", :build]
    end
    """
  let parsed = try XcodeSimulatorTools.parse(Data(formula.utf8))
  #expect(parsed.version == "0.9.12")
  #expect(parsed.url.lastPathComponent == "applesimutils-0.9.12.arm64_big_sur.bottle.tar.gz")
  for changed in [
    formula.replacingOccurrences(of: "arm64_big_sur", with: "big_sur"),
    formula.replacingOccurrences(of: "root_url '", with: "root_url 'https://example.com/"),
    formula.replacingOccurrences(
      of: "AppleSimulatorUtils-0.9.12", with: "AppleSimulatorUtils-0.9.11"),
    formula + "\n depends_on \"unexpected\"\n",
    formula + "\n revision 1\n",
    formula + "\n resource \"extra\" do\n end\n",
    formula + "\n bottle do\n end\n",
  ] {
    #expect(throws: MisoError.self) { try XcodeSimulatorTools.parse(Data(changed.utf8)) }
  }
}

import Foundation
import Testing
@testable import MisoCore

@Test func sharedDigest() {
  #expect(SafeFile.sha256(Data("hello".utf8)) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

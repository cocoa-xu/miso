import Testing

@testable import MisoCore

@Test(arguments: [
  (">=18.*", "24.19.0", true), (">=18.*", "17.9.9", false),
  (">= 18.12.0 <20 || >=22", "22.0.0", true),
  (">=18 <20 || >=22", "21.0.0", false),
  ("^0.2.5", "0.3.0", false), ("^0.0.4", "0.0.5", false),
  ("^0.0", "0.0.99", true), ("^0", "0.9.9", true),
  ("~1.2", "1.3.0", false), ("~1", "1.9.9", true),
  ("1.2 - 2.3", "2.3.99", true), ("1.2 - 2.3", "2.4.0", false),
  (">1.2", "1.3.0", true), ("<=1.2", "1.2.99", true),
  ("<=1.2", "1.3.0", false), ("1.x", "1.8.0", true),
  (">=20.0.0-0", "20.0.0", true), ("<20.0.0-0", "20.0.0", false),
  (">20.0.0-0", "20.0.0", true), ("<=20.0.0-0", "20.0.0", false),
  ("=20.0.0-0", "20.0.0", false), ("18 - 20.0.0-0", "20.0.0", false),
  ("*", "24.0.0", true), (">*", "24.0.0", false),
])
func npmEngineRequirementsFollowStableRangeSemantics(
  _ range: String, _ version: String, _ matches: Bool
)
  throws
{
  #expect(try VersionRequirement(range, syntax: .npm).contains(version) == matches)
}

@Test(arguments: [
  (">= 3.2.0", "4.0.7", true), (">= 3.2.0", "2.7.8", false),
  ("~> 2.2", "2.9.0", true), ("~> 2.2.0", "2.3.0", false),
  (">=2.0, != 2.1.0, <3", "2.1.0", false),
  (">=2.0, != 2.1.0, <3", "2.2.0", true),
])
func rubyGemRequirementsRespectPessimisticBounds(
  _ range: String, _ version: String, _ matches: Bool
)
  throws
{
  #expect(try VersionRequirement(range, syntax: .gem).contains(version) == matches)
}

@Test(arguments: ["^", "1.x.3", ">=latest", ">=1.0.0-beta.1", "~>1", "1.2.3.4", "1 | 2"])
func unknownNPMRequirementsFailClosed(_ range: String) {
  #expect(throws: (any Error).self) { try VersionRequirement(range, syntax: .npm) }
}

import Darwin
import MisoSystem
import Testing

@Suite struct GuestPolicyTests {
  func policy(root: String = "/private/tmp/guest", user: String = "admin", capability: String)
    -> (Int32, String)
  {
    var buffer = [CChar](repeating: 0, count: 65536)
    let result = miso_guest_policy(root, user, capability, &buffer, buffer.count)
    return (result, String(cString: buffer))
  }

  @Test func capabilitiesAreNarrow() {
    let read = policy(capability: "read-only")
    #expect(read.0 == 0)
    #expect(read.1.contains("(deny network*)"))
    #expect(read.1.contains("(deny mach-lookup)"))
    #expect(!read.1.contains("/opt/homebrew"))
    let base = policy(capability: "base")
    #expect(base.0 == 0)
    #expect(base.1.contains("/private/tmp/guest/System/Volumes/Data/opt/homebrew"))
    #expect(!base.1.contains(".rbenv"))
    #expect(!base.1.contains(".gitconfig"))
    #expect(!base.1.contains("allow network"))
    #expect(policy(capability: "ruby").1.contains(".rbenv"))
    #expect(policy(capability: "git").1.contains(".gitconfig.lock"))
    #expect(policy(capability: "brew").1.contains("allow network-bind"))
  }

  @Test func rejectsPolicyInjectionAndAmbiguousPaths() {
    for root in [
      "/", "relative", "/tmp/", "/tmp//guest", "/tmp/../guest", "/tmp/./guest",
      "/tmp/\"guest", "/tmp/\\guest", "/tmp/\nguest", "/tmp/\rguest",
    ] {
      #expect(policy(root: root, capability: "base").0 == EINVAL)
    }
    for user in ["", "root/../../", "admin\"", "Admin", "a\n", String(repeating: "a", count: 32)] {
      #expect(policy(user: user, capability: "base").0 == EINVAL)
    }
    #expect(policy(capability: "all").0 == EINVAL)
    var buffer = [CChar](repeating: 0, count: 8)
    #expect(miso_guest_policy("/tmp/guest", "admin", "base", &buffer, buffer.count) == EOVERFLOW)
  }

  @Test func casksCanWriteOnlyTheirReviewedApplication() {
    let cask = policy(capability: "cask")
    #expect(cask.0 == 0)
    #expect(cask.1.contains("(deny network*)"))
    #expect(cask.1.contains("(deny mach-lookup)"))
    #expect(cask.1.contains("(subpath \"/Applications/Kiro CLI.app\")"))
    #expect(cask.1.contains("/private/tmp/guest/System/Volumes/Data/Applications/Kiro CLI.app"))
    #expect(!cask.1.contains("(subpath \"/Applications\")"))
    #expect(!policy(capability: "brew").1.contains("/Applications/"))
  }
}

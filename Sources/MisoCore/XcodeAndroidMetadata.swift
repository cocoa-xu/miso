import CryptoKit
import Foundation

enum XcodeAndroidMetadata {
  static func localPackage(_ repository: Data, package: XcodeAndroidInputs.Package) throws -> Data {
    let selection = try XcodeAndroidInputs.parse(repository)
    guard selection.packages.contains(package) else {
      throw MisoError.invalid("Installed Android package differs from repository")
    }
    let document = try XMLDocument(data: repository, options: [.nodeLoadExternalEntitiesNever])
    guard let root = document.rootElement(),
      let remote = root.elements(forName: "remotePackage").first(where: {
        $0.attribute(forName: "path")?.stringValue == package.identifier
      }),
      let license = root.elements(forName: "license").first(where: {
        $0.attribute(forName: "id")?.stringValue == package.license
      })
    else { throw MisoError.invalid("Missing Android package metadata") }
    let local = XMLElement(name: "localPackage")
    local.addAttribute(
      XMLNode.attribute(withName: "path", stringValue: package.identifier) as! XMLNode)
    for name in ["type-details", "revision", "display-name", "uses-license"] {
      let matches = remote.elements(forName: name)
      guard matches.count == 1 else {
        throw MisoError.invalid("Missing Android local field: \(name)")
      }
      local.addChild(matches[0].copy() as! XMLNode)
    }
    let installed = XMLElement(name: "common:repository")
    for namespace in root.namespaces ?? [] {
      installed.addNamespace(namespace.copy() as! XMLNode)
    }
    installed.addChild(license.copy() as! XMLNode)
    installed.addChild(local)
    let result = XMLDocument(rootElement: installed)
    result.characterEncoding = "UTF-8"
    return result.xmlData(options: [.nodePrettyPrint])
  }

  static func licenseDigest(_ terms: String) -> String {
    SafeFile.hex(
      Insecure.SHA1.hash(data: Data(terms.utf8)))
  }
}

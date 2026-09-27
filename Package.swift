// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "miso",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MisoCore", targets: ["MisoCore"]),
    .executable(name: "miso", targets: ["MisoCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
  ],
  targets: [
    .systemLibrary(name: "CMiso"),
    .target(name: "MisoSystem"),
    .target(name: "MisoCore", dependencies: ["CMiso", "MisoSystem", "ZIPFoundation"]),
    .executableTarget(
      name: "MisoCLI",
      dependencies: [
        "MisoCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(name: "MisoCoreTests", dependencies: ["MisoCore", "ZIPFoundation"]),
  ]
)

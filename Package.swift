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
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", exact: "1.0.0"),
  ],
  targets: [
    .systemLibrary(name: "CMiso"),
    .systemLibrary(name: "CZstd"),
    .target(name: "MisoSystem"),
    .target(
      name: "MisoCore",
      dependencies: [
        "CMiso", "CZstd", "MisoSystem", "ZIPFoundation", "Yams",
        .product(name: "ArchiveKit", package: "libarchive.xcframework"),
      ]),
    .executableTarget(
      name: "MisoCLI",
      dependencies: [
        "MisoCore", "MisoSystem",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(
      name: "MisoCoreTests", dependencies: ["MisoCore", "ZIPFoundation"],
      resources: [.copy("Fixtures")]),
  ]
)

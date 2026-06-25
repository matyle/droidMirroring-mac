// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MirrorEngine",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "MirrorEngine", targets: ["MirrorEngine"]),
  ],
  dependencies: [
    .package(path: "../ScrcpyClient"),
    .package(path: "../SharedModels"),
  ],
  targets: [
    .target(
      name: "MirrorEngine",
      dependencies: ["ScrcpyClient", "SharedModels"]
    ),
    .testTarget(
      name: "MirrorEngineTests",
      dependencies: ["MirrorEngine"]
    ),
  ]
)

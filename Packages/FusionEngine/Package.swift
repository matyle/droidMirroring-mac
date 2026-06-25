// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FusionEngine",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "FusionEngine", targets: ["FusionEngine"]),
  ],
  dependencies: [
    .package(path: "../ADBKit"),
    .package(path: "../ScrcpyClient"),
    .package(path: "../MirrorEngine"),
    .package(path: "../SharedModels"),
  ],
  targets: [
    .target(
      name: "FusionEngine",
      dependencies: ["ADBKit", "ScrcpyClient", "MirrorEngine", "SharedModels"]
    ),
    .testTarget(
      name: "FusionEngineTests",
      dependencies: ["FusionEngine", "ADBKit", "ScrcpyClient", "MirrorEngine", "SharedModels"]
    ),
  ]
)

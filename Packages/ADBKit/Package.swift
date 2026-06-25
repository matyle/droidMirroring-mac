// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ADBKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "ADBKit", targets: ["ADBKit"]),
    .executable(name: "sync-smoke", targets: ["SyncSmoke"]),
  ],
  dependencies: [
    .package(path: "../SharedModels"),
  ],
  targets: [
    .target(
      name: "ADBKit",
      dependencies: ["SharedModels"]
    ),
    .executableTarget(
      name: "SyncSmoke",
      dependencies: ["ADBKit", "SharedModels"]
    ),
    .testTarget(
      name: "ADBKitTests",
      dependencies: ["ADBKit"]
    ),
  ]
)

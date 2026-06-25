// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ScrcpyClient",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "ScrcpyClient", targets: ["ScrcpyClient"]),
    .executable(name: "scrcpy-smoke", targets: ["ScrcpySmoke"]),
  ],
  dependencies: [
    .package(path: "../ADBKit"),
    .package(path: "../SharedModels"),
  ],
  targets: [
    .target(
      name: "ScrcpyClient",
      dependencies: ["ADBKit", "SharedModels"]
    ),
    .executableTarget(
      name: "ScrcpySmoke",
      dependencies: ["ScrcpyClient", "ADBKit", "SharedModels"]
    ),
    .testTarget(
      name: "ScrcpyClientTests",
      dependencies: ["ScrcpyClient"]
    ),
  ]
)

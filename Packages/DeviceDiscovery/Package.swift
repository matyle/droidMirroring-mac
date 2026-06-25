// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DeviceDiscovery",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DeviceDiscovery", targets: ["DeviceDiscovery"]),
  ],
  dependencies: [
    .package(path: "../SharedModels"),
    .package(path: "../ADBKit"),
  ],
  targets: [
    .target(
      name: "DeviceDiscovery",
      dependencies: ["SharedModels", "ADBKit"]
    ),
  ]
)

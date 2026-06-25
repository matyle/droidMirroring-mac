// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SharedModels",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "SharedModels", targets: ["SharedModels"]),
  ],
  targets: [
    .target(name: "SharedModels"),
  ]
)

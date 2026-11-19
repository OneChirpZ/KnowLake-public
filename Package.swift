// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = []

let package = Package(
    name: "KnowLake", platforms: [.macOS(.v14)],
    products: [.executable(name: "KnowLake", targets: ["KnowLake"])],
    targets: [
        .executableTarget(name: "KnowLake", resources: [.copy("Resources")], swiftSettings: settings),
        .testTarget(name: "KnowLakeTests", dependencies: ["KnowLake"], swiftSettings: settings)
    ], swiftLanguageModes: [.v5]
)

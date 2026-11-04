// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TesCam",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "TeslaCamKit", targets: ["TeslaCamKit"]),
        .executable(name: "tescam", targets: ["tescam-cli"]),
    ],
    targets: [
        .target(name: "TeslaCamKit"),
        .executableTarget(name: "tescam-cli", dependencies: ["TeslaCamKit"]),
        .testTarget(name: "TeslaCamKitTests", dependencies: ["TeslaCamKit"]),
    ],
    swiftLanguageModes: [.v5]
)

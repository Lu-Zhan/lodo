// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LodoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LodoCore", targets: ["LodoCore"]),
    ],
    targets: [
        .target(name: "LodoCore"),
        .testTarget(name: "LodoCoreTests", dependencies: ["LodoCore"]),
    ]
)

// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HulderCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "HulderCore", targets: ["HulderCore"]),
    ],
    targets: [
        .target(name: "HulderCore"),
        .testTarget(name: "HulderCoreTests", dependencies: ["HulderCore"]),
    ]
)

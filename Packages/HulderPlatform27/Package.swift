// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HulderPlatform27",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "HulderPlatform27", targets: ["HulderPlatform27"]),
    ],
    dependencies: [
        .package(path: "../HulderCore"),
    ],
    targets: [
        .target(name: "HulderPlatform27", dependencies: [.product(name: "HulderCore", package: "HulderCore")]),
        .testTarget(name: "HulderPlatform27Tests", dependencies: [
            "HulderPlatform27",
            .product(name: "HulderCore", package: "HulderCore"),
        ]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAdBlock",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacAdBlockCore", targets: ["MacAdBlockCore"])
    ],
    targets: [
        .target(name: "MacAdBlockCore"),
        .testTarget(name: "MacAdBlockCoreTests", dependencies: ["MacAdBlockCore"])
    ]
)

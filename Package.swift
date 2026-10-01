// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupecast",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "LoupecastCore"),
        .target(name: "LoupecastRender", dependencies: ["LoupecastCore"]),
        .executableTarget(name: "Loupecast", dependencies: ["LoupecastCore", "LoupecastRender"]),
        .testTarget(name: "LoupecastCoreTests", dependencies: ["LoupecastCore"]),
        .testTarget(name: "LoupecastRenderTests", dependencies: ["LoupecastCore", "LoupecastRender"]),
    ]
)

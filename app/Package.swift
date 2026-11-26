// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Netfuse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Netfuse", path: "Sources/Netfuse"),
        .testTarget(name: "NetfuseTests", dependencies: ["Netfuse"], path: "Tests/NetfuseTests"),
    ]
)

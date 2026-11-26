// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nethance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Nethance", path: "Sources/Nethance"),
        .testTarget(name: "NethanceTests", dependencies: ["Nethance"], path: "Tests/NethanceTests"),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Peek",
            path: "Sources/Peek",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "PeekTests", dependencies: ["Peek"])
    ]
)

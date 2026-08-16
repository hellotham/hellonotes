// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmbedBench",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "EmbedBench",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ]
)

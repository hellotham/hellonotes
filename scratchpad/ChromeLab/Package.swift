// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChromeLab",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ChromeLab", path: "Sources/ChromeLab")
    ]
)

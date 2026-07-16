// swift-tools-version: 6.2
//
//  NotesEditor — HelloNotes' own Markdown editing engine.
//
//  MarkdownCore     platform-free kernel: incremental block/inline parsing
//                   and the pure style specification. Foundation-only,
//                   Sendable, fully unit-tested.
//  MarkdownEditor   the TextKit 2 editor UI (AppKit + UIKit + SwiftUI).
//
//  Design rationale: docs/editor-rewrite.md at the repository root.
//
import PackageDescription

let package = Package(
    name: "NotesEditor",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
        .library(name: "MarkdownEditor", targets: ["MarkdownEditor"]),
    ],
    targets: [
        .target(
            name: "MarkdownCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarkdownEditor",
            dependencies: ["MarkdownCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "MarkdownCoreTests",
            dependencies: ["MarkdownCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

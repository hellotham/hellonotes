// swift-tools-version: 6.2
//
//  NotesEditor — HelloNotes' own Markdown editing engine.
//
//  MarkdownCore     platform-free kernel: incremental block/inline parsing
//                   and the pure style specification. Foundation-only,
//                   Sendable, fully unit-tested.
//  MarkdownEditor   the TextKit 2 editor UI (AppKit + UIKit + SwiftUI).
//  GFMRender        GitHub-identical Markdown → HTML via cmark-gfm (the same
//                   engine GitHub uses), verified against the GFM spec corpus.
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
        .library(name: "GFMRender", targets: ["GFMRender"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .target(
            name: "MarkdownCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MarkdownEditor",
            dependencies: ["MarkdownCore", "GFMRender"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        .target(
            name: "GFMRender",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            resources: [
                .copy("github-markdown.css"),
                .copy("highlight.min.js"),
                .copy("hljs-github.css"),
                .copy("hljs-github-dark.css"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarkdownCoreTests",
            dependencies: ["MarkdownCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MarkdownEditorTests",
            dependencies: ["MarkdownEditor", "GFMRender"],
            resources: [.copy("spec.txt")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GFMRenderTests",
            dependencies: ["GFMRender"],
            resources: [
                .copy("spec.txt"),
                .copy("github-parity-input.md"),
                .copy("github-parity-expected.html"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

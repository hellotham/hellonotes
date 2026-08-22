// swift-tools-version: 6.0
//
//  RenderParity — measures Edit against Preview, headlessly.
//
//  The live editor lays the document out in TextKit and Preview lays it out in
//  WebKit. Whether those two agree is a question about *rendered geometry*, and
//  it can only be answered by rendering: reasoning about how TextKit
//  distributes leading, or about which CSS margins collapse, is exactly how the
//  two drifted apart in the first place. So this loads the same Markdown into
//  both engines offscreen, asks each where every block ended up, and prints the
//  difference.
//
import PackageDescription

let package = Package(
    name: "RenderParity",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../Packages/NotesEditor")],
    targets: [
        .executableTarget(
            name: "RenderParity",
            dependencies: [
                .product(name: "MarkdownEditor", package: "NotesEditor"),
                .product(name: "MarkdownCore", package: "NotesEditor"),
                .product(name: "GFMRender", package: "NotesEditor"),
            ]
        )
    ]
)

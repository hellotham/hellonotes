//
//  MermaidPreviewView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

// **Cross-platform.** Gated for an `NSImage` render-and-flip this file kept
// privately; the shared renderer does both, on both platforms.
import SwiftUI
import BeautifulMermaid
import MarkdownEditor

/// A sheet that renders the note's ```mermaid blocks as native images (via
/// BeautifulMermaid — no WebView). The editor has no inline code-block
/// render hook, so diagrams preview here rather than inside the editor.
struct MermaidPreviewView: View {
    let sources: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Mermaid Diagrams", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                        DiagramCell(index: index + 1, source: source)
                    }
                }
                .padding()
            }
        }
        .frame(width: 680, height: 560)
    }
}

private struct DiagramCell: View {
    let index: Int
    let source: String
    @State private var image: PlatformImage?
    @State private var didRender = false
    @Environment(\.colorScheme) private var colorScheme

    /// `MermaidDiagramRenderer.standaloneImage` rather than a local render and
    /// flip. This file had its own `NSImage` copy of both — including the
    /// bottom-left-origin correction, which `PlatformImageOrient.uprightMermaid`
    /// already does for the editor's inline diagrams on both platforms. One
    /// renderer, so a diagram in the preview cannot come out different from the
    /// same diagram in a note.
    private static func makeImage(_ source: String, isDark: Bool) -> PlatformImage? {
        MermaidDiagramRenderer.standaloneImage(source: source, isDark: isDark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagram \(index)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background)
            } else if didRender {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Couldn't render this diagram", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(source)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(.quaternary.opacity(0.4))
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding()
            }
        }
        // Render once (not on every body eval / scroll). Still main-actor
        // (MermaidRenderer + lockFocus are main-only), but no longer repeated.
        .task(id: source) {
            image = Self.makeImage(source, isDark: colorScheme == .dark)
            didRender = true
        }
    }
}

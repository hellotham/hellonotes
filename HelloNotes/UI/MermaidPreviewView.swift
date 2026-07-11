//
//  MermaidPreviewView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI
import BeautifulMermaid

/// A sheet that renders the note's ```mermaid blocks as native images (via
/// BeautifulMermaid — no WebView). MarkdownEngine has no inline code-block
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

    private var image: NSImage? {
        guard let rendered = (try? MermaidRenderer.renderImage(source: source)) ?? nil else { return nil }
        return Self.flippedVertically(rendered)
    }

    /// BeautifulMermaid renders into a Core Graphics context (bottom-left
    /// origin), so the resulting `NSImage` is upside down when shown top-left.
    /// Redraw it flipped so diagrams display right-way-up.
    private static func flippedVertically(_ image: NSImage) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let flipped = NSImage(size: size)
        flipped.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: size.height)
        transform.scaleX(by: 1, yBy: -1)
        transform.concat()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        flipped.unlockFocus()
        return flipped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagram \(index)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background)
            } else {
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
            }
        }
    }
}
#endif

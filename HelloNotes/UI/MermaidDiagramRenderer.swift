//
//  MermaidDiagramRenderer.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import AppKit
import BeautifulMermaid

/// Renders ```` ```mermaid ```` fences to inline images, via BeautifulMermaid
/// (no WebView). Used by the editor's block-embed renderer and the
/// transclusion card. Transparent background + zinc theme by appearance, so
/// the diagram reads well against the note in light and dark.
enum MermaidDiagramRenderer {
    /// Render a Mermaid diagram to an image. BeautifulMermaid renders into a
    /// bottom-left-origin CoreGraphics context, so the result is flipped
    /// vertically to read right-way-up when drawn top-left.
    nonisolated static func standaloneImage(source: String, isDark: Bool) -> NSImage? {
        let theme = (isDark ? DiagramTheme.zincDark : DiagramTheme.zincLight).withTransparent()
        guard let image = (try? MermaidRenderer.renderImage(source: source, theme: theme)) ?? nil,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return flippedVertically(image)
    }

    nonisolated private static func flippedVertically(_ image: NSImage) -> NSImage {
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
}
#endif

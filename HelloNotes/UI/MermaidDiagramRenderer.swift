//
//  MermaidDiagramRenderer.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import CoreGraphics
import BeautifulMermaid
import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Renders ```` ```mermaid ```` fences to inline images, via BeautifulMermaid
/// (no WebView). Used by the editor's block-embed renderer and the
/// transclusion card. Transparent background + zinc theme by appearance, so
/// the diagram reads well against the note in light and dark.
enum MermaidDiagramRenderer {
    /// Render a Mermaid diagram to an image. On macOS BeautifulMermaid draws
    /// into a bottom-left-origin CoreGraphics context, so the result is flipped
    /// to read upright; on iOS it renders through `UIGraphicsImageRenderer`
    /// (already upright), so no flip is needed.
    nonisolated static func standaloneImage(source: String, isDark: Bool) -> PlatformImage? {
        let theme = (isDark ? DiagramTheme.zincDark : DiagramTheme.zincLight).withTransparent()
        guard let image = (try? MermaidRenderer.renderImage(source: source, theme: theme)) ?? nil,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return PlatformImageOrient.uprightMermaid(image)
    }
}

/// Orientation helpers shared by the Mermaid renderer and the transclusion card.
enum PlatformImageOrient {
    /// BeautifulMermaid's macOS output is bottom-left-origin; flip it upright.
    /// iOS output is already upright.
    nonisolated static func uprightMermaid(_ image: PlatformImage) -> PlatformImage {
        #if canImport(AppKit)
        return flippedVertically(image)
        #else
        return image
        #endif
    }

    #if canImport(AppKit)
    nonisolated static func flippedVertically(_ image: NSImage) -> NSImage {
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
    #endif
}

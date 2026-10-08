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

/// Renders ```` ```mermaid ```` fences via BeautifulMermaid (no WebView): as
/// images for the editor's block-embed renderer, Preview and the transclusion
/// card, and as a vector drawing for the zoom. Transparent background + zinc
/// theme by appearance, so the diagram reads well against the note in light
/// and dark.
enum MermaidDiagramRenderer {
    /// Render a Mermaid diagram to an image. On macOS BeautifulMermaid draws
    /// into a bottom-left-origin CoreGraphics context, so the result is flipped
    /// to read upright; on iOS it renders through `UIGraphicsImageRenderer`
    /// (already upright), so no flip is needed.
    nonisolated static func standaloneImage(source: String, isDark: Bool) -> PlatformImage? {
        guard let image = (try? MermaidRenderer.renderImage(source: source, theme: theme(isDark))) ?? nil,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return PlatformImageOrient.uprightMermaid(image)
    }

    /// The diagram laid out once, to be drawn as vectors at whatever size it is
    /// shown — for the zoom, where a bitmap enlarged past its own resolution
    /// goes soft. Nil if the source does not parse.
    ///
    /// The same parse, layout and theme as `standaloneImage`, so the diagram in
    /// the zoom is the diagram in the note. `nonisolated` and main-actor-free:
    /// parsing and layout are computation, so the zoom prepares off the main
    /// actor — as the editor's render does, now that `standaloneImage`'s macOS
    /// flip is CoreGraphics rather than AppKit.
    nonisolated static func drawing(source: String, isDark: Bool) -> DiagramDrawing? {
        guard let positioned = try? MermaidRenderer.layout(source),
              positioned.width > 0, positioned.height > 0 else { return nil }
        return DiagramDrawing(positioned: positioned, theme: theme(isDark))
    }

    /// Transparent, so the diagram reads on the note's own canvas.
    private nonisolated static func theme(_ isDark: Bool) -> DiagramTheme {
        (isDark ? DiagramTheme.zincDark : DiagramTheme.zincLight).withTransparent()
    }
}

/// A laid-out Mermaid diagram that draws itself into any context, at any
/// scale — vectors all the way down, so 800% is as sharp as 100%.
nonisolated struct DiagramDrawing: Sendable {
    /// The diagram's own size, in points: what 100% is.
    let size: CGSize
    private let positioned: PositionedGraph
    private let theme: DiagramTheme

    init(positioned: PositionedGraph, theme: DiagramTheme) {
        self.positioned = positioned
        self.theme = theme
        size = CGSize(width: positioned.width, height: positioned.height)
    }

    /// Draw at the context's current transform, top-left at its origin. The
    /// context must be y-down — a SwiftUI canvas's is.
    ///
    /// Labels are drawn by AppKit and UIKit string drawing, which draw into
    /// their *own* notion of the current context rather than the one handed
    /// to `render`: set that to this one for the duration, or the text lands
    /// somewhere else — or, on iOS, nowhere. `flipped: false` on the Mac is
    /// what the renderer would make for itself: it flips each label locally.
    func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        #if canImport(AppKit)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        #endif
        DiagramRenderer(theme: theme).render(positioned, in: context,
                                             bounds: CGRect(origin: .zero, size: size))
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
    /// Through a bitmap `CGContext`, not `NSImage.lockFocus`, which is
    /// main-thread-only — the same route `PlatformImageKit.scaled` takes. The
    /// flip was the one thing that kept a diagram's whole render (parse,
    /// layout, rasterise: 123ms at 120 nodes) on the main actor; drawn this
    /// way it can run anywhere. Pixel for pixel: the context is the source
    /// bitmap's own size.
    nonisolated static func flippedVertically(_ image: NSImage) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.translateBy(x: 0, y: CGFloat(source.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let flipped = context.makeImage() else { return image }
        return PlatformImageKit.image(cgImage: flipped, size: size)
    }
    #else
    /// BeautifulMermaid's iOS output comes from `UIGraphicsImageRenderer` and is
    /// already upright, so the flip is the identity here. Written out because
    /// "this platform does not need the flip" and "this platform has no flip"
    /// are different claims, and `uprightMermaid` above depends on the first.
    nonisolated static func flippedVertically(_ image: UIImage) -> UIImage { image }
    #endif
}

//
//  BlockRendering.swift
//  MarkdownEditor
//
//  Inline rendering of block embeds — a standalone `![[image]]`, a
//  ```mermaid fence, a `$$…$$` math block — as images drawn *in place* of
//  their source. Storage stays pure Markdown: the source characters remain,
//  concealed while the caret is outside the block and revealed (for editing)
//  when the caret enters it.
//
//  The engine that produces the images is injected by the host (a
//  `BlockRenderer`), so the editor stays free of image/diagram/math
//  dependencies. Results are cached per content hash on the document and
//  re-applied synchronously on restyle — the same no-flash pattern as code
//  highlighting.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A block embed the editor can ask the host to render.
public enum BlockEmbedKind: Sendable, Equatable, Hashable {
    /// `![[target]]` — an embedded image/attachment by vault name.
    case image(target: String)
    /// A ```` ```mermaid ```` fenced diagram.
    case mermaid(source: String)
    /// A `$$ … $$` display-math block.
    case math(source: String)
}

/// Renders block embeds to images sized to fit `maxWidth` (points, the text
/// container's usable width). Runs off the main actor. Return nil to leave
/// the source visible (unknown target, render failure, unsupported kind).
public protocol BlockRenderer: Sendable {
    func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage?
}

/// Custom attribute carrying the rendered image for a collapsed block. The
/// fragment draws it in the band reserved by the paragraph's `paragraphSpacing`.
nonisolated let blockImageAttribute = NSAttributedString.Key("hn.blockImage")

#if canImport(AppKit)
/// An `NSTextLayoutFragment` that draws a collapsed block's rendered image in
/// the vertical band its paragraph reserves via `paragraphSpacing`. Only
/// active for fragments whose text carries `blockImageAttribute`; everything
/// else falls through to the default fragment behavior.
nonisolated final class RenderedBlockFragment: NSTextLayoutFragment {

    /// Gap (points) between the concealed source line and the image, and
    /// below the image before following text.
    static let imageGap: CGFloat = 6

    private var textStorage: NSTextStorage? {
        (textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage
    }

    private var fragmentRange: NSRange? {
        guard let tcs = textLayoutManager?.textContentManager as? NSTextContentStorage else { return nil }
        let start = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: rangeInElement.endLocation)
        guard start != NSNotFound, end != NSNotFound, end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The image (if any) this fragment must draw, plus the y offset of the
    /// top of the reserved band relative to the fragment's draw origin.
    private func blockImage() -> (image: NSImage, bandTop: CGFloat)? {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length,
              let image = ts.attribute(blockImageAttribute, at: range.location, effectiveRange: nil) as? NSImage
        else { return nil }
        // The concealed source line sits at the fragment top; the image band
        // begins just below it. The first line fragment's height is that
        // collapsed line.
        let lineHeight = textLineFragments.first?.typographicBounds.height ?? 2
        return (image, lineHeight + Self.imageGap)
    }

    override nonisolated var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let (image, bandTop) = blockImage() {
            let rect = CGRect(x: 0, y: bandTop, width: image.size.width, height: image.size.height)
            bounds = bounds.union(rect)
        }
        return bounds
    }

    override nonisolated func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)   // concealed source (invisible)
        guard let (image, bandTop) = blockImage() else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let leftInset = point.x - layoutFragmentFrame.origin.x
            + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0)
        let rect = CGRect(x: leftInset, y: point.y + bandTop,
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect)
    }
}

/// Vends `RenderedBlockFragment` so block images can draw. Cheap: the
/// fragment only does extra work when its text carries a block image.
final class RenderedBlockLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        RenderedBlockFragment(textElement: textElement, range: textElement.elementRange)
    }
}
#endif

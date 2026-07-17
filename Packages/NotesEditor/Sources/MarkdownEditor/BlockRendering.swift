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
    /// A GFM pipe table (full block source, including the delimiter row).
    case table(source: String)
}

/// Renders block embeds to images sized to fit `maxWidth` (points, the text
/// container's usable width). Runs off the main actor. Return nil to leave
/// the source visible (unknown target, render failure, unsupported kind).
public protocol BlockRenderer: Sendable {
    func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage?
    /// Render an inline `$…$` math span at (roughly) `fontSize`. Optional.
    func renderInlineMath(_ latex: String, fontSize: CGFloat, darkMode: Bool) async -> PlatformImage?
}

public extension BlockRenderer {
    func renderInlineMath(_ latex: String, fontSize: CGFloat, darkMode: Bool) async -> PlatformImage? { nil }
}

/// Custom attribute carrying the rendered image for a collapsed block. The
/// fragment draws it in the band reserved by the paragraph's `paragraphSpacing`.
nonisolated let blockImageAttribute = NSAttributedString.Key("hn.blockImage")

/// Custom attribute (Bool = checked) marking a task-list `[ ]`/`[x]` box.
/// The fragment draws a checkbox glyph over the (concealed) brackets; the
/// text view toggles it on click.
nonisolated public let taskCheckboxAttribute = NSAttributedString.Key("hn.taskCheckbox")

/// Custom attribute (PlatformColor) on every line of a callout — the
/// fragment paints a tinted full-width band + an accent bar in the gutter.
nonisolated public let calloutTintAttribute = NSAttributedString.Key("hn.calloutTint")
/// Custom attribute (String SF Symbol name) on a callout's header line —
/// the fragment paints the icon in the gutter beside the title.
nonisolated public let calloutIconAttribute = NSAttributedString.Key("hn.calloutIcon")

/// Custom attribute (PlatformImage) on the first char of a concealed inline
/// `$…$` math span — the fragment draws it at the baseline. The span's source
/// is made invisible and its width reserved (via `.kern`) to match the image.
nonisolated public let inlineImageAttribute = NSAttributedString.Key("hn.inlineImage")

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

    override nonisolated func draw(at point: CGPoint, in context: CGContext) {
        drawCalloutBands(at: point, in: context)   // behind the text
        super.draw(at: point, in: context)   // concealed source (invisible)
        drawTaskCheckboxes(at: point, in: context)
        drawInlineImages(at: point, in: context)

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

    // MARK: - Task checkboxes

    /// Draw a checkbox glyph over every concealed `[ ]`/`[x]` box on top of
    /// the (invisible) bracket characters, so the width and layout are
    /// unchanged and the box sits exactly where the source is.
    private nonisolated func drawTaskCheckboxes(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        ts.enumerateAttribute(taskCheckboxAttribute, in: range, options: []) { value, attrRange, _ in
            guard let checked = value as? Bool,
                  let pos = charPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? PlatformFont)
                ?? .systemFont(ofSize: NSFont.systemFontSize)
            let side = max(10, (font.ascender - font.descender) * 0.95)
            let box = CGRect(x: pos.x, y: pos.baselineY - font.ascender + (font.ascender - font.descender - side) / 2,
                             width: side, height: side)
            let symbol = checked ? "checkmark.square.fill" : "square"
            let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                img.draw(in: box)
            }
        }
    }

    // MARK: - Callouts

    override nonisolated var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let (image, bandTop) = blockImage() {
            bounds = bounds.union(CGRect(x: 0, y: bandTop, width: image.size.width, height: image.size.height))
        }
        if hasCallout, let width = textLayoutManager?.textContainer?.size.width {
            bounds.origin.x = -layoutFragmentFrame.origin.x
            bounds.size.width = width
        }
        return bounds
    }

    private nonisolated var hasCallout: Bool {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length else { return false }
        var found = false
        ts.enumerateAttribute(calloutTintAttribute, in: range, options: []) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// Paint a tinted full-width band + an accent bar in the gutter for every
    /// callout line, and the header line's SF Symbol icon.
    private nonisolated func drawCalloutBands(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let barWidth: CGFloat = 3

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let leftEdge = point.x - layoutFragmentFrame.origin.x
        for line in textLineFragments {
            let docStart = range.location + line.characterRange.location
            guard docStart < ts.length,
                  let tint = ts.attribute(calloutTintAttribute, at: docStart, effectiveRange: nil) as? NSColor
            else { continue }
            let tb = line.typographicBounds
            let band = CGRect(x: leftEdge, y: point.y + tb.origin.y, width: containerWidth, height: tb.height)
            tint.withAlphaComponent(0.10).setFill()
            NSBezierPath(rect: band).fill()
            tint.withAlphaComponent(0.85).setFill()
            NSBezierPath(rect: CGRect(x: leftEdge, y: band.minY, width: barWidth, height: tb.height)).fill()

            if let symbol = ts.attribute(calloutIconAttribute, at: docStart, effectiveRange: nil) as? String,
               let icon = calloutIcon(symbol, tint: tint) {
                let side: CGFloat = 13
                let rect = CGRect(x: leftEdge + barWidth + 4,
                                  y: band.minY + (tb.height - side) / 2, width: side, height: side)
                icon.draw(in: rect)
            }
        }
    }

    private nonisolated func calloutIcon(_ symbol: String, tint: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(hierarchicalColor: tint))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Inline images (inline `$…$` math)

    /// Draw each inline-math image at the baseline of its (invisible,
    /// width-reserved) source span.
    private nonisolated func drawInlineImages(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        ts.enumerateAttribute(inlineImageAttribute, in: range, options: []) { value, attrRange, _ in
            guard let image = value as? NSImage,
                  let line = lineFragment(forDocumentCharAt: attrRange.location),
                  let pos = charPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            // Center on the line fragment's vertical middle (the concealed
            // source char is near-zero-height, so use the line, not its font).
            let tb = line.typographicBounds
            let lineMidY = point.y + tb.origin.y + tb.height / 2
            let rect = CGRect(x: pos.x, y: lineMidY - image.size.height / 2,
                              width: image.size.width, height: image.size.height)
            image.draw(in: rect)
        }
    }

    private nonisolated func lineFragment(forDocumentCharAt docIndex: Int) -> NSTextLineFragment? {
        guard let fragRange = fragmentRange else { return nil }
        let local = docIndex - fragRange.location
        guard local >= 0 else { return nil }
        for line in textLineFragments {
            let lr = line.characterRange
            if local >= lr.location && local < lr.location + lr.length { return line }
        }
        return nil
    }

    /// Draw position (x, baselineY) for the character at document offset
    /// `docIndex`, within this fragment.
    private nonisolated func charPosition(forDocumentCharAt docIndex: Int, point: CGPoint) -> (x: CGFloat, baselineY: CGFloat)? {
        guard let fragRange = fragmentRange else { return nil }
        let local = docIndex - fragRange.location
        guard local >= 0 else { return nil }
        for line in textLineFragments {
            let lr = line.characterRange
            if local >= lr.location && local < lr.location + lr.length {
                let charPos = line.locationForCharacter(at: local)
                let tb = line.typographicBounds
                return (x: point.x + tb.origin.x + charPos.x, baselineY: point.y + tb.origin.y + charPos.y)
            }
        }
        return nil
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

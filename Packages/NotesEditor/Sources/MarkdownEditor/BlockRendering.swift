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
/// Custom attribute (Bool = isFolded) on a callout header line — the fragment
/// draws a right-aligned disclosure chevron; the text view toggles fold on a
/// click there. Present only on foldable (multi-line) callout headers.
nonisolated public let calloutFoldAttribute = NSAttributedString.Key("hn.calloutFold")
/// Custom attribute (Int = nesting depth) on a concealed unordered-list
/// marker — the fragment draws a bullet glyph (disc/ring/square) in its place.
nonisolated public let listBulletAttribute = NSAttributedString.Key("hn.listBullet")
/// Marks a plain (non-callout) blockquote line so the fragment draws only a
/// gutter bar — no tint fill, no icon.
nonisolated public let blockquotePlainAttribute = NSAttributedString.Key("hn.blockquotePlain")
/// Custom attribute (Int level) on an h1/h2 heading line — the fragment draws a
/// full-width bottom rule below it, matching GitHub's heading borders.
nonisolated public let headingRuleAttribute = NSAttributedString.Key("hn.headingRule")

/// Custom attribute (PlatformImage) on the first char of a concealed inline
/// `$…$` math span — the fragment draws it at the baseline. The span's source
/// is made invisible and its width reserved (via `.kern`) to match the image.
nonisolated public let inlineImageAttribute = NSAttributedString.Key("hn.inlineImage")

/// An `NSTextLayoutFragment` that draws a collapsed block's rendered image in
/// the vertical band its paragraph reserves via `paragraphSpacing`, plus the
/// editor's chrome (bullets, callout bands, heading rules, checkboxes). Only
/// active for fragments whose text carries the relevant attributes; everything
/// else falls through to the default fragment behavior. Cross-platform: all
/// drawing is CoreGraphics (TextKit 2 + `NSTextLayoutFragment` exist on iOS 15+).
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
    private func blockImage() -> (image: PlatformImage, bandTop: CGFloat)? {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length,
              let image = ts.attribute(blockImageAttribute, at: range.location, effectiveRange: nil) as? PlatformImage
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
        drawListBullets(at: point, in: context)
        drawHeadingRule(at: point, in: context)
        drawInlineImages(at: point, in: context)

        guard let (image, bandTop) = blockImage(), let cg = PlatformDraw.cgImage(image) else { return }
        let leftInset = point.x - layoutFragmentFrame.origin.x
            + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0)
        let rect = CGRect(x: leftInset, y: point.y + bandTop,
                          width: image.size.width, height: image.size.height)
        PlatformDraw.image(cg, in: rect, context: context)
    }

    /// Draw only the chrome (no text, no block-embed image) at `point`. Used by
    /// the iOS overlay renderer, since `UITextView` doesn't invoke a custom
    /// fragment's `draw(at:in:)` the way `NSTextView` does.
    nonisolated func drawChromeOnly(at point: CGPoint, in context: CGContext) {
        drawCalloutBands(at: point, in: context)
        drawTaskCheckboxes(at: point, in: context)
        drawListBullets(at: point, in: context)
        drawHeadingRule(at: point, in: context)
        drawInlineImages(at: point, in: context)
    }

    // MARK: - Task checkboxes

    /// Draw a checkbox glyph over every concealed `[ ]`/`[x]` box on top of
    /// the (invisible) bracket characters, so the width and layout are
    /// unchanged and the box sits exactly where the source is.
    private nonisolated func drawTaskCheckboxes(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        ts.enumerateAttribute(taskCheckboxAttribute, in: range, options: []) { value, attrRange, _ in
            guard let checked = value as? Bool,
                  let pos = charPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            let font = (ts.attribute(.font, at: attrRange.location, effectiveRange: nil) as? PlatformFont)
                ?? .systemFont(ofSize: PlatformFont.systemFontSize)
            let side = max(10, (font.ascender - font.descender) * 0.95)
            let box = CGRect(x: pos.x, y: pos.baselineY - font.ascender + (font.ascender - font.descender - side) / 2,
                             width: side, height: side)
            let symbol = checked ? "checkmark.square.fill" : "square"
            if let cg = PlatformDraw.symbol(symbol, pointSize: side, color: .editorLabel) {
                PlatformDraw.image(cg, in: box, context: context)
            }
        }
    }

    // MARK: - Heading rule (h1/h2 bottom border, GitHub-style)

    private nonisolated func drawHeadingRule(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length,
              ts.attribute(headingRuleAttribute, at: range.location, effectiveRange: nil) != nil,
              let lastLine = textLineFragments.last else { return }
        let tb = lastLine.typographicBounds
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        let y = point.y + tb.origin.y + tb.height + 7
        PlatformDraw.fill(CGRect(x: leftEdge, y: y, width: width, height: 1), .editorSeparator, in: context)
    }

    // MARK: - List bullets

    /// Draw a bullet glyph over each concealed unordered-list marker: a filled
    /// disc, hollow ring, or filled square by nesting depth (GitHub-style).
    private nonisolated func drawListBullets(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        ts.enumerateAttribute(listBulletAttribute, in: range, options: []) { value, attrRange, _ in
            guard let depth = value as? Int,
                  let line = lineFragment(forDocumentCharAt: attrRange.location),
                  let pos = charPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            let tb = line.typographicBounds
            let side: CGFloat = 5
            let cx = pos.x + 1
            let cy = point.y + tb.origin.y + tb.height / 2
            let rect = CGRect(x: cx, y: cy - side / 2, width: side, height: side)
            switch depth % 3 {
            case 1:                                   // hollow ring
                PlatformDraw.strokeEllipse(rect.insetBy(dx: 0.4, dy: 0.4), .editorLabel, lineWidth: 1, in: context)
            case 2:                                   // filled square
                PlatformDraw.fill(rect.insetBy(dx: 0.4, dy: 0.4), .editorLabel, in: context)
            default:                                  // filled disc
                PlatformDraw.fillEllipse(rect, .editorLabel, in: context)
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
        let leftEdge = point.x - layoutFragmentFrame.origin.x
        for line in textLineFragments {
            let docStart = range.location + line.characterRange.location
            guard docStart < ts.length,
                  let tint = ts.attribute(calloutTintAttribute, at: docStart, effectiveRange: nil) as? PlatformColor
            else { continue }
            let tb = line.typographicBounds
            let band = CGRect(x: leftEdge, y: point.y + tb.origin.y, width: containerWidth, height: tb.height)
            // Plain blockquotes: one gutter bar per `>` nesting level, no fill.
            // Callouts: a tinted band + a single accent bar.
            if let depth = ts.attribute(blockquotePlainAttribute, at: docStart, effectiveRange: nil) as? Int {
                for level in 0..<max(1, depth) {
                    let x = leftEdge + CGFloat(level) * RenderedBlockFragment.quoteBarStep
                    PlatformDraw.fill(CGRect(x: x, y: band.minY, width: barWidth, height: tb.height),
                                      tint.withAlphaComponent(0.55), in: context)
                }
            } else {
                PlatformDraw.fill(band, tint.withAlphaComponent(0.10), in: context)
                PlatformDraw.fill(CGRect(x: leftEdge, y: band.minY, width: barWidth, height: tb.height),
                                  tint.withAlphaComponent(0.85), in: context)
            }

            if let symbol = ts.attribute(calloutIconAttribute, at: docStart, effectiveRange: nil) as? String,
               let icon = PlatformDraw.symbol(symbol, pointSize: 12, color: tint) {
                let side: CGFloat = 13
                let rect = CGRect(x: leftEdge + barWidth + 4,
                                  y: band.minY + (tb.height - side) / 2, width: side, height: side)
                PlatformDraw.image(icon, in: rect, context: context)
            }

            // Foldable callout: a right-aligned disclosure chevron.
            if let folded = ts.attribute(calloutFoldAttribute, at: docStart, effectiveRange: nil) as? Bool,
               let chevron = PlatformDraw.symbol(folded ? "chevron.right" : "chevron.down", pointSize: 11, color: tint) {
                let side: CGFloat = 11
                let rect = CGRect(x: band.maxX - Self.calloutChevronInset,
                                  y: band.minY + (tb.height - side) / 2, width: side, height: side)
                PlatformDraw.image(chevron, in: rect, context: context)
            }
        }
    }

    /// Distance from the band's right edge to the fold chevron's left edge.
    static let calloutChevronInset: CGFloat = 22
    /// Horizontal distance between successive nested blockquote bars (matches
    /// `StyleApplier.quoteBarStep`).
    static let quoteBarStep: CGFloat = 12

    // MARK: - Inline images (inline `$…$` math)

    /// Draw each inline-math image at the baseline of its (invisible,
    /// width-reserved) source span.
    private nonisolated func drawInlineImages(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        ts.enumerateAttribute(inlineImageAttribute, in: range, options: []) { value, attrRange, _ in
            guard let image = value as? PlatformImage, let cg = PlatformDraw.cgImage(image),
                  let line = lineFragment(forDocumentCharAt: attrRange.location),
                  let pos = charPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            // Center on the line fragment's vertical middle (the concealed
            // source char is near-zero-height, so use the line, not its font).
            let tb = line.typographicBounds
            let lineMidY = point.y + tb.origin.y + tb.height / 2
            let rect = CGRect(x: pos.x, y: lineMidY - image.size.height / 2,
                              width: image.size.width, height: image.size.height)
            PlatformDraw.image(cg, in: rect, context: context)
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

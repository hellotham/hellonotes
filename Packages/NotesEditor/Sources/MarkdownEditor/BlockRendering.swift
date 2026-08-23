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
import MarkdownCore
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
    /// A raw HTML block (its full source, tags and all).
    ///
    /// `keepsTrailingMargin` is the element's own `margin-bottom`, and it is
    /// part of the *kind* because it is part of the picture: an HTML block
    /// carries no margin of its own in `GFMBoxMetrics` precisely so that the
    /// rendered fragment's height decides, and a `<table>`'s 16pt lives inside
    /// that height. GitHub zeroes `margin-bottom` on `.markdown-body >
    /// *:last-child`, so a note *ending* in one has no such space — and the
    /// editor reserved it anyway, standing 16pt tall against a page that
    /// painted nothing there (spec #130, #142, #652).
    case html(source: String, keepsTrailingMargin: Bool)
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

/// Where the reserved band starts, relative to the drawing fragment's origin
/// (CGFloat). Present only when the band could not be made of `paragraphSpacing`
/// — see `EditorDocument.collapse(range:to:)` — in which case the band *is* the
/// line box and the offset cannot be derived from the collapsed line's height.
nonisolated let blockImageTopAttribute = NSAttributedString.Key("hn.blockImageTop")

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
/// Custom attribute (CGFloat) on a blockquote line whose paragraph spacing is
/// *inside* the quote — between its own paragraphs, or above a nested one — so
/// the bar covers it. Absent on the quote's last line, where the spacing is the
/// margin below the box and a border must not extend into it.
nonisolated public let quoteBarExtraAttribute = NSAttributedString.Key("hn.quoteBarExtra")
/// Custom attribute (Int level) on an h1/h2 heading line — the fragment draws a
/// full-width bottom rule below it, matching GitHub's heading borders.
nonisolated public let headingRuleAttribute = NSAttributedString.Key("hn.headingRule")
/// Custom attribute (CGFloat) on the first char of a block's **last** line:
/// space to reserve below it that must not be dropped at the end of the note.
/// `RenderedBlockFragment.bottomMargin` returns it. See `StyleApplier`'s
/// `keepARulesBottomMargin` for the one thing it is for.
nonisolated public let escapingMarginAttribute = NSAttributedString.Key("hn.escapingMargin")
/// Custom attribute (CGFloat) on the first char of a block's **first** line:
/// space to reserve *above* it that must not be dropped at the start of the
/// note. `RenderedBlockFragment.topMargin` returns it.
///
/// The mirror of `escapingMarginAttribute`, and it exists for the same reason
/// the code box's bottom padding does. A `<p>` inside a loose `<li>`, or a
/// heading opening one, has a `margin-top` that collapses straight out through
/// the `<li>` and the `<ul>` — and at the very top of a note there is nothing
/// above for it to collapse into, so the page simply starts that much lower.
/// TextKit drops `paragraphSpacingBefore` on the document's first paragraph
/// outright, so the space used to be added to the *line height* instead — and a
/// line height applies to every **wrapped** visual line, so an opening item long
/// enough to wrap paid the margin once per line. At a 420pt pane that is 16pt of
/// invented space on the first item of half the notes in the fixture folder;
/// at 800 nothing wraps and nothing shows.
nonisolated public let openingMarginAttribute = NSAttributedString.Key("hn.openingMargin")
/// Custom attribute (CGFloat) carrying the document's base font size on every
/// styled run. Chrome drawing happens inside an `NSTextLayoutFragment`, which
/// has a text storage and no theme; without this the fragment had to hard-code
/// the gutter step, the rule offset and the bar width, so they stayed at their
/// 16pt-base values while Text Size moved everything around them.
nonisolated public let gfmBaseAttribute = NSAttributedString.Key("hn.gfmBase")
/// Custom attribute (CGFloat thickness) on a collapsed `---` line — the
/// fragment fills it as GitHub's `hr` bar.
nonisolated public let thematicBreakAttribute = NSAttributedString.Key("hn.thematicBreak")
/// Custom attribute (Int: 0 top, 1 middle, 2 bottom, 3 whole) on each line of a
/// code block — the fragment paints `pre`'s rounded background behind it.
nonisolated public let codeBandAttribute = NSAttributedString.Key("hn.codeBand")
/// Custom attribute (CGFloat) on a code line that carries `pre`'s
/// **padding-bottom**: space reserved below the line box, inside the box, which
/// `drawCodeBand` paints over.
///
/// The padding used to be part of the line height, with the glyphs "lifted off
/// it" by a negative `.baselineOffset` — and that lift moves the *reported*
/// baseline and not the ink (measured: a 20pt change moves the glyph zero
/// pixels), so the two cancelled exactly. The box was the right height, the
/// listing sat hard against the bottom of it, and no height measurement could
/// see the difference: `render-parity.sh`'s baseline column reads
/// `glyphOrigin`, which has the offset already applied — the instrument
/// confirms its own input.
///
/// `NSTextLayoutFragment.bottomMargin` is where such space goes, for the same
/// reason an h1's rule inset does: it is *inside* the fragment, below every
/// line box, counted once per paragraph however many lines it wraps to, and
/// not dropped at the end of the note the way `paragraphSpacing` is. Four
/// sites reserve it — a top-level indented block, an unclosed fence, a code
/// block inside a list item, and one inside a blockquote — and they all spell
/// it this way so that one repair covers them.
nonisolated public let codeBottomPadAttribute = NSAttributedString.Key("hn.codeBottomPad")
/// Custom attribute (CGFloat horizontal padding) on an inline `code` span — the
/// fragment paints its rounded pill. The padding itself is reserved by `.kern`
/// on the concealed backticks either side, so the text after the span lands
/// where the Preview puts it.
nonisolated public let inlineCodeAttribute = NSAttributedString.Key("hn.inlineCode")

/// Custom attribute (PlatformImage) on the first char of a concealed inline
/// `$…$` math span — the fragment draws it at the baseline. The span's source
/// is made invisible and its width reserved (via `.kern`) to match the image.
nonisolated public let inlineImageAttribute = NSAttributedString.Key("hn.inlineImage")

/// Custom attribute (CGFloat) beside `inlineImageAttribute` when the picture is
/// an **inline replaced element** — an `![…](…)` or an `<img>` inside a line of
/// prose — rather than an inline formula.
///
/// Two things follow from that distinction, which is why it is an attribute and
/// not a flag on the drawing code. A formula is a *phrase*: it is set in the
/// middle of the line and centring it there is what reads correctly. A replaced
/// element **sits on the baseline** — CSS gives it `vertical-align: baseline`,
/// which is the whole reason its line box grows: the box has to reach up the
/// image's full height from the baseline, and a 20pt picture on a 24pt line
/// makes it 26.
///
/// The value is how far *below* the line's reported baseline the glyphs are
/// actually inked — the half-leading `StyleApplier` puts on every run of the
/// paragraph. `NSTextLineFragment.glyphOrigin.y` comes back with that lift
/// already taken off and AppKit draws from the unlifted one, so an image seated
/// straight from `glyphOrigin` floats a half-leading above the letters beside
/// it. Carried here rather than read back off `.baselineOffset` at the same
/// character, because that character's offset is no longer the paragraph's: it
/// is the raise that grows the line box in the first place.
nonisolated public let inlineImageBaselineAttribute = NSAttributedString.Key("hn.inlineImageBaseline")

/// Every attribute that makes a fragment draw chrome over its own text, or
/// reserve space around it.
///
/// Collapsing a block used to mean four attributes — a concealed font, a clear
/// colour and a paragraph style — because the only things ever collapsed were a
/// table's pipes, a `$$` fence and a run of tags, and none of those carries any
/// chrome. A rendered HTML *span* covers whatever Markdown sits between the
/// tags, and its chrome survived the collapse: an indented code block inside a
/// `<table>` span kept `codeBottomPadAttribute`, which is a fragment's
/// `bottomMargin` and not a paragraph style, so the picture stood 16pt off the
/// bottom of a box nothing painted (spec #160).
nonisolated let chromeAttributes: [NSAttributedString.Key] = [
    taskCheckboxAttribute, calloutTintAttribute, calloutIconAttribute,
    calloutFoldAttribute, listBulletAttribute, blockquotePlainAttribute,
    quoteBarExtraAttribute, headingRuleAttribute, escapingMarginAttribute,
    openingMarginAttribute,
    thematicBreakAttribute, codeBandAttribute, codeBottomPadAttribute,
    inlineCodeAttribute, inlineImageAttribute, inlineImageBaselineAttribute,
]

/// An `NSTextLayoutFragment` that draws a collapsed block's rendered image in
/// the vertical band its paragraph reserves via `paragraphSpacing`, plus the
/// editor's chrome (bullets, callout bands, heading rules, checkboxes). Only
/// active for fragments whose text carries the relevant attributes; everything
/// else falls through to the default fragment behavior. Cross-platform: all
/// drawing is CoreGraphics (TextKit 2 + `NSTextLayoutFragment` exist on iOS 15+).
nonisolated final class RenderedBlockFragment: NSTextLayoutFragment {

    /// Gap (points) between the concealed source line and the image, and below
    /// the image before following text.
    ///
    /// Zero, because the rendered page has no such gap: a `<table>` or an
    /// `<img>` sits flush in its box and is separated from what follows by the
    /// block margin, which the block already carries. Six points here put
    /// twelve on every rendered table, diagram, formula and HTML block — a
    /// spacing number living in a renderer instead of in `GFMBoxMetrics`,
    /// which is the one thing the box model forbids. Kept as a named constant
    /// rather than deleted so the band arithmetic still reads as arithmetic.
    static let imageGap: CGFloat = 0

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
        // Normally the concealed source line sits at the fragment top and the
        // image band begins just below it, so the first line fragment's height
        // is the offset. When the band had to be made *of* the line box instead
        // (a block that ends the document), that height is the whole band and
        // the offset comes with the image.
        if let top = ts.attribute(blockImageTopAttribute, at: range.location,
                                  effectiveRange: nil) as? CGFloat {
            return (image, top)
        }
        let lineHeight = textLineFragments.first?.typographicBounds.height ?? 2
        return (image, lineHeight + Self.imageGap)
    }

    override nonisolated func draw(at point: CGPoint, in context: CGContext) {
        drawCodeBand(at: point, in: context)       // behind everything
        drawCalloutBands(at: point, in: context)   // behind the text
        drawInlineCodePills(at: point, in: context)
        super.draw(at: point, in: context)   // concealed source (invisible)
        drawTaskCheckboxes(at: point, in: context)
        drawListBullets(at: point, in: context)
        drawHeadingRule(at: point, in: context)
        drawThematicBreak(at: point, in: context)
        drawInlineImages(at: point, in: context)

        drawBlockImage(at: point, in: context)
    }

    /// The rendered table / diagram / display-maths image, in the band that
    /// `EditorDocument.collapse(range:to:)` reserved for it.
    private nonisolated func drawBlockImage(at point: CGPoint, in context: CGContext) {
        guard let (image, bandTop) = blockImage(), let cg = PlatformDraw.cgImage(image) else { return }
        let leftInset = point.x - layoutFragmentFrame.origin.x
            + (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0)
        let rect = CGRect(x: leftInset, y: point.y + bandTop,
                          width: image.size.width, height: image.size.height)
        PlatformDraw.image(cg, in: rect, context: context)
    }

    /// Draw everything except the text at `point` — chrome *and* the block
    /// image. Used by the iOS overlay renderer, since `UITextView` doesn't
    /// invoke a custom fragment's `draw(at:in:)` the way `NSTextView` does.
    ///
    /// The block image belongs here, not only in `draw`: leaving it out is why
    /// a table on iPad stayed as pipes and dashes. The source is concealed and
    /// a band is reserved for the image either way, so omitting the draw left
    /// an empty band rather than a table.
    nonisolated func drawChromeOnly(at point: CGPoint, in context: CGContext) {
        drawCodeBand(at: point, in: context)
        drawCalloutBands(at: point, in: context)
        drawInlineCodePills(at: point, in: context)
        drawTaskCheckboxes(at: point, in: context)
        drawListBullets(at: point, in: context)
        drawHeadingRule(at: point, in: context)
        drawThematicBreak(at: point, in: context)
        drawInlineImages(at: point, in: context)
        drawBlockImage(at: point, in: context)
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
              let level = ts.attribute(headingRuleAttribute, at: range.location,
                                       effectiveRange: nil) as? Int,
              let lastLine = textLineFragments.last else { return }
        let m = metrics(at: range.location)
        let tb = lastLine.typographicBounds
        // Inset by the box's own indent, so a heading inside a list item rules
        // off its item and not the whole column.
        let para = ts.attribute(.paragraphStyle, at: range.location,
                                effectiveRange: nil) as? NSParagraphStyle
        let boxIndent = max(0, para?.headIndent ?? 0)
        let width = contentWidth - boxIndent
        let leftEdge = point.x - layoutFragmentFrame.origin.x + contentInset + boxIndent
        // `h1, h2 { padding-bottom: .3em }` then the border itself — .3 of the
        // *heading's* size, so an h1's rule sits further below its text than an
        // h2's. A fixed 7pt put both in the wrong place at every text size.
        let y = point.y + tb.origin.y + tb.height + m.headingSize(level) * GFMBoxMetrics.headingRulePadRatio
        PlatformDraw.fill(CGRect(x: leftEdge, y: y, width: width, height: m.hairline),
                          .editorSeparator, in: context)
    }

    /// Where the *content* starts, and how wide it is.
    ///
    /// Chrome that spans the column — an h1's rule, a blockquote's bar, a code
    /// block's box — was drawn from the text container's own edge, which is one
    /// `lineFragmentPadding` further left than the first glyph. CSS draws these
    /// borders on the content box, flush with the text, so every one of them
    /// sat 5pt left of where the Preview put it and ran 5pt long at each end.
    /// `drawBlockImage` already allowed for the padding; the chrome did not.
    private nonisolated var contentInset: CGFloat {
        textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
    }

    private nonisolated var contentWidth: CGFloat {
        let container = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return max(0, container - 2 * contentInset)
    }

    /// The document's box model, read off the text itself.
    private nonisolated func metrics(at location: Int) -> GFMBoxMetrics {
        guard let ts = textStorage, location < ts.length,
              let base = ts.attribute(gfmBaseAttribute, at: location, effectiveRange: nil) as? CGFloat
        else { return GFMBoxMetrics() }
        return GFMBoxMetrics(base: base)
    }

    // MARK: - Thematic break

    /// `hr` — a bar of its own height, not a line of dashes.
    private nonisolated func drawThematicBreak(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length,
              let thickness = ts.attribute(thematicBreakAttribute, at: range.location,
                                           effectiveRange: nil) as? CGFloat,
              let line = textLineFragments.first else { return }
        let tb = line.typographicBounds
        let width = contentWidth
        let leftEdge = point.x - layoutFragmentFrame.origin.x + contentInset
        PlatformDraw.fill(CGRect(x: leftEdge, y: point.y + tb.origin.y, width: width, height: thickness),
                          .editorSeparator, in: context)
    }

    // MARK: - Code block background

    /// `pre { background: var(--bgColor-muted); border-radius: 6px }`.
    ///
    /// A code block is many paragraphs and therefore many layout fragments, so
    /// the box is painted a line at a time and only the first and last line
    /// round their corners. Painting it as a text background attribute (which
    /// is what the editor did) fills behind the glyphs and nothing else: a
    /// short line left a ragged right edge and the 16pt padding had no colour
    /// at all.
    private nonisolated func drawCodeBand(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length,
              let position = ts.attribute(codeBandAttribute, at: range.location,
                                          effectiveRange: nil) as? Int else { return }
        let m = metrics(at: range.location)
        // Inset by however far the box itself is indented. A `pre` at the top
        // level has `headIndent == codePadding`, so this is zero and nothing
        // changes; one *inside a blockquote* is indented past the gutter, and
        // the band used to ignore that and paint the full column — straight
        // through the quote bar.
        let para = ts.attribute(.paragraphStyle, at: range.location,
                                effectiveRange: nil) as? NSParagraphStyle
        let boxIndent = max(0, (para?.headIndent ?? m.codePadding) - m.codePadding)
        let width = contentWidth - boxIndent
        let leftEdge = point.x - layoutFragmentFrame.origin.x + contentInset + boxIndent
        var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
        for line in textLineFragments {
            let tb = line.typographicBounds
            top = min(top, tb.origin.y)
            bottom = max(bottom, tb.origin.y + tb.height)
        }
        guard bottom > top else { return }
        // …and down over `padding-bottom`, which is not in any line box: it is
        // the fragment's `bottomMargin`. Painting only the line boxes left the
        // colour stopping level with the last line of the listing while the
        // box went on for another 16pt — which is the same picture as having
        // no bottom padding at all, and is how it read.
        let pad = ts.attribute(codeBottomPadAttribute, at: range.location,
                               effectiveRange: nil) as? CGFloat ?? 0
        // A padding band has nothing in it to measure. The delimiter line it
        // stands on is concealed, so its typographic bounds are the *concealed
        // font's* — a couple of points — while the paragraph style pins the
        // fragment to the box's 16pt. Painting the bounds drew a sliver and the
        // listing then appeared to start 13.5pt inside its own box, with every
        // height measurement agreeing. Paint the fragment, which is what the
        // padding actually is.
        let isPaddingBand = (position == 0 || position == 2)
            && bottom - top < layoutFragmentFrame.height - 1
        let rect = isPaddingBand
            ? CGRect(x: leftEdge, y: point.y, width: width, height: layoutFragmentFrame.height)
            : CGRect(x: leftEdge, y: point.y + top, width: width, height: bottom - top + pad)
        PlatformDraw.fill(rect, .editorCodeBackground, radius: m.codeRadius,
                          roundTop: position == 0 || position == 3,
                          roundBottom: position == 2 || position == 3, in: context)
    }

    // MARK: - List bullets

    /// Draw a bullet glyph over each concealed unordered-list marker: a filled
    /// disc, hollow ring, or filled square by nesting depth (GitHub-style).
    private nonisolated func drawListBullets(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        let m = metrics(at: range.location)
        ts.enumerateAttribute(listBulletAttribute, in: range, options: []) { value, attrRange, _ in
            guard let depth = value as? Int,
                  let line = lineFragment(forDocumentCharAt: attrRange.location),
                  let pos = charPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            let tb = line.typographicBounds
            let side: CGFloat = 5
            // Centred in the item's own padding, which is where CSS puts a
            // list marker: `ul { padding-left: 2em }`, and the disc sits half
            // way along it. Drawn from the concealed marker's character
            // position it ended up hard against the text — 10pt from it where
            // the rendered page leaves 16.
            let para = ts.attribute(.paragraphStyle, at: attrRange.location,
                                    effectiveRange: nil) as? NSParagraphStyle
            let indent = para?.headIndent ?? 0
            let cx = indent > 0
                ? point.x - layoutFragmentFrame.origin.x + contentInset + indent - m.listIndent / 2
                : pos.x + 1
            // Centred on the *x-height*, not on the line box.
            //
            // A line box's midpoint sits above the visual middle of lowercase
            // text, because the box is the full ascender plus descender while
            // the letters occupy the x-height between them. Centring there put
            // every bullet up level with the cap height, where the rendered
            // page puts it beside the middle of the word.
            // `glyphOrigin.y` reports the baseline *with* the half-leading lift
            // already taken off, while the glyphs are drawn from the unlifted
            // one — so a bullet placed straight from it lands a half-leading
            // high, level with the cap height. Put the lift back before
            // measuring. (Measured: 15px above the baseline where the rendered
            // page puts it at 9, on a 2× dump.)
            // The font of the *text*, not of the marker: the marker is concealed
            // at a hundredth of a point, and its x-height is therefore zero —
            // which put the bullet on the baseline instead of beside the word.
            let textAt = min(attrRange.location + attrRange.length, ts.length - 1)
            let font = ts.attribute(.font, at: max(0, textAt), effectiveRange: nil) as? PlatformFont
            let lift = ts.attribute(.baselineOffset, at: attrRange.location,
                                    effectiveRange: nil) as? CGFloat ?? 0
            let xHeight = font?.xHeight ?? (tb.height * 0.5)
            let cy = point.y + tb.origin.y + line.glyphOrigin.y - lift - xHeight / 2
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

    /// `code { padding: .2em .4em; border-radius: 6px; background: … }`.
    ///
    /// A `.backgroundColor` attribute paints behind the glyphs and nowhere
    /// else, so it drew a tight rectangle with no padding at all — and the
    /// padding is not decoration: in the Preview it advances the text, so every
    /// word after an inline code span on the same line sat nine and a half
    /// points left of where the Preview put it.
    private nonisolated func drawInlineCodePills(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        ts.enumerateAttribute(inlineCodeAttribute, in: range, options: []) { value, span, _ in
            guard let pad = value as? CGFloat, span.length > 0,
                  let line = lineFragment(forDocumentCharAt: span.location),
                  let start = charPosition(forDocumentCharAt: span.location, point: point)
            else { return }
            // The span's right-hand edge is the closing backtick's position:
            // it is concealed to nothing and carries the trailing padding as
            // kerning, so it sits exactly where the pill ends.
            let after = NSMaxRange(span)
            let end = after < ts.length
                ? charPosition(forDocumentCharAt: after, point: point)?.x
                : nil
            let left = start.x - pad
            let right = end ?? (start.x + pad)
            guard right > left else { return }
            // The pill covers the code font's own content box plus `.2em`
            // above and below, centred on the line — which is what an inline
            // box's background covers in CSS, and not the whole 1.5 line box.
            let size = (ts.attribute(.font, at: span.location, effectiveRange: nil)
                        as? PlatformFont)?.pointSize ?? pad * 2.5
            let tb = line.typographicBounds
            let height = min(tb.height, size * 1.56)
            let rect = CGRect(x: left, y: point.y + tb.origin.y + (tb.height - height) / 2,
                              width: right - left, height: height)
            PlatformDraw.fill(rect, .editorInlineCodeBackground,
                              radius: metrics(at: span.location).codeRadius,
                              roundTop: true, roundBottom: true, in: context)
        }
    }

    // MARK: - Space below the last line

    /// The heading level whose bottom rule this fragment carries, if any.
    ///
    /// Read from the text rather than the block list, because a fragment knows
    /// nothing about blocks: `StyleApplier` marks the first character of every
    /// h1/h2 — top level, inside a list item, either spelling — and this is
    /// the only thing that has to agree with it.
    private nonisolated var headingRuleLevel: Int? {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length else { return nil }
        return ts.attribute(headingRuleAttribute, at: range.location,
                            effectiveRange: nil) as? Int
    }

    /// Space reserved below the fragment's last line: an h1/h2's
    /// `padding-bottom: .3em` plus the border itself, and any margin the end of
    /// the note would otherwise throw away.
    ///
    /// The padding is the whole point. GitHub gives an h1 two different things below
    /// its text: `padding-bottom` (inside the element, above the border) and
    /// `margin-bottom` (outside it). TextKit has one obvious place to put
    /// space below a paragraph — `paragraphSpacing` — and it drops that value
    /// on the document's *last* paragraph. That is correct for the margin, and
    /// GitHub does the same to `:last-child`; it is wrong for the padding,
    /// which CSS never drops. So a note ending in an h1 stood ~11pt short of
    /// its Preview and clipped its own rule off the bottom of the note.
    ///
    /// `bottomMargin` is the padding, despite the name: it is the space
    /// between the last line and the bottom of the *fragment*, i.e. inside the
    /// box, and the fragment exists at EOF like any other. `paragraphSpacing`
    /// stays as the margin, and stays dropped at EOF. One is padding and one is
    /// margin, which is exactly why one must survive there and the other must
    /// not.
    ///
    /// It is also the only mechanism here that does not multiply by the wrap
    /// count. The tempting repair — folding the inset into `minimumLineHeight`
    /// — was tried and reverted: a line height applies to every *wrapped*
    /// visual line, and `StyleApplier` styles without knowing the pane's
    /// width, so a heading that wrapped to three lines gained the inset three
    /// times. `bottomMargin` is per fragment, i.e. per paragraph, however many
    /// lines that paragraph wraps to.
    ///
    /// Deliberately does not consult `textLineFragments`: this is asked
    /// *during* layout, and the line fragments are what layout is producing.
    /// Space above the fragment — see `openingMarginAttribute`. Counted once
    /// per fragment, which is the whole point of putting it here.
    override nonisolated var topMargin: CGFloat {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length,
              let opening = ts.attribute(openingMarginAttribute, at: range.location,
                                         effectiveRange: nil) as? CGFloat
        else { return super.topMargin }
        return super.topMargin + opening
    }

    override nonisolated var bottomMargin: CGFloat {
        guard let range = fragmentRange else { return super.bottomMargin }
        var extra: CGFloat = 0
        if let level = headingRuleLevel {
            extra += metrics(at: range.location).headingRuleInset(level)
        }
        // A margin that CSS keeps at the end of the note, parked here for the
        // same reason: `paragraphSpacing` would be dropped. See
        // `escapingMarginAttribute`.
        if let ts = textStorage, range.location < ts.length,
           let escaping = ts.attribute(escapingMarginAttribute, at: range.location,
                                       effectiveRange: nil) as? CGFloat {
            extra += escaping
        }
        // `pre { padding-bottom }`. Padding, exactly like the heading rule's —
        // and for the same reason it cannot live in the line height: a line
        // height is *per visual line*, so a wrapped listing would pay it twice,
        // and the glyphs would sit in the middle of the space rather than above
        // it. See `codeBottomPadAttribute`.
        if let ts = textStorage, range.location < ts.length,
           let pad = ts.attribute(codeBottomPadAttribute, at: range.location,
                                  effectiveRange: nil) as? CGFloat {
            extra += pad
        }
        return super.bottomMargin + extra
    }

    // MARK: - Callouts

    override nonisolated var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let (image, bandTop) = blockImage() {
            bounds = bounds.union(CGRect(x: 0, y: bandTop, width: image.size.width, height: image.size.height))
        }
        if drawsFullWidthChrome, let width = textLayoutManager?.textContainer?.size.width {
            bounds.origin.x = -layoutFragmentFrame.origin.x
            bounds.size.width = width
        }
        // An h1/h2 rule is drawn *below* the line box, in the padding the
        // heading reserves through `bottomMargin` — outside the surface a
        // fragment is given by default, so it was simply clipped away. (A
        // thematic break, drawn inside its own line box, was never affected,
        // which is what made the two behave differently in the same list.)
        if let level = headingRuleLevel, let range = fragmentRange,
           let tb = textLineFragments.last?.typographicBounds {
            let m = metrics(at: range.location)
            let needed = tb.maxY + m.headingRuleInset(level)
            if needed > bounds.maxY { bounds.size.height = needed - bounds.minY }
        }
        // The same for a code box's bottom padding: reserved outside the line
        // boxes, so the surface a fragment is given by default stops short of
        // it and the paint is clipped away without a word.
        if let ts = textStorage, let range = fragmentRange, range.length > 0,
           range.location < ts.length,
           let pad = ts.attribute(codeBottomPadAttribute, at: range.location,
                                  effectiveRange: nil) as? CGFloat,
           let tb = textLineFragments.last?.typographicBounds {
            let needed = tb.maxY + pad
            if needed > bounds.maxY { bounds.size.height = needed - bounds.minY }
        }
        return bounds
    }

    /// Whether this fragment paints something that spans the text container
    /// rather than the fragment's own text.
    ///
    /// A fragment is clipped to its `renderingSurfaceBounds`, which by default
    /// is the width of the text it holds — so an h1's bottom rule stopped at
    /// the end of the word "Introduction" instead of crossing the column, and a
    /// code block's background ended at its longest line. Both are drawn full
    /// width and both were being cut off, which is only visible in a picture:
    /// the geometry is right, the paint is clipped.
    private nonisolated var drawsFullWidthChrome: Bool {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0,
              range.location < ts.length else { return false }
        if ts.attribute(headingRuleAttribute, at: range.location, effectiveRange: nil) != nil { return true }
        if ts.attribute(codeBandAttribute, at: range.location, effectiveRange: nil) != nil { return true }
        if ts.attribute(thematicBreakAttribute, at: range.location, effectiveRange: nil) != nil { return true }
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
        let containerWidth = contentWidth
        // `blockquote { border-left: .25em }` — the same bar GitHub draws.
        let barWidth = metrics(at: range.location).quoteBorder
        let leftEdge = point.x - layoutFragmentFrame.origin.x + contentInset
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
                let m = metrics(at: docStart)
                // The bar runs the height of the *box*, not of the line: where
                // the quote's own paragraphs are spaced apart the border does
                // not break. Only that spacing — the gap below the whole quote
                // is margin, which sits outside the border, and taking the
                // line's spacing unconditionally ran the bar past the end of
                // the quote.
                var spacing = ts.attribute(quoteBarExtraAttribute, at: docStart,
                                           effectiveRange: nil) as? CGFloat ?? 0
                // A code box's bottom padding is *inside* the quote — it is
                // inside the `pre`, which is inside the `blockquote` — so the
                // border runs past it. Without this the bar stopped level with
                // the last line of a quoted listing and left a 16pt notch
                // where the box goes on.
                if line === textLineFragments.last,
                   let pad = ts.attribute(codeBottomPadAttribute, at: range.location,
                                          effectiveRange: nil) as? CGFloat {
                    spacing += pad
                }
                // The same for a quoted h1/h2's rule: `padding-bottom` and the
                // border are inside the heading, which is inside the
                // blockquote, so the quote's own border runs past both. Left
                // out, the bar stopped level with the heading's text and the
                // rule was drawn across a notch in it.
                if line === textLineFragments.last, let level = headingRuleLevel {
                    spacing += metrics(at: range.location).headingRuleInset(level)
                }
                for level in 0..<max(1, depth) {
                    let x = leftEdge + CGFloat(level) * m.quoteIndent
                    // `border-left: .25em solid var(--borderColor-default)` —
                    // the border colour at full strength. It was the muted
                    // *text* colour at 55%, which is neither that colour nor
                    // any colour the Preview draws.
                    // Snapped to whole points, so consecutive lines' segments
                    // meet. At fractional edges they did not quite: a quote
                    // drew as a bar with hairline seams across it, one per line
                    // break, where the rendered page draws one unbroken border.
                    let top = band.minY.rounded(.down)
                    let bottom = (band.minY + tb.height + spacing).rounded(.up)
                    PlatformDraw.fill(CGRect(x: x, y: top, width: m.quoteBorder,
                                             height: bottom - top),
                                      .editorSeparator, in: context)
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

    // MARK: - Inline images (inline `$…$` math)

    /// Draw each inline image in the (invisible, width-reserved) span its
    /// source occupies: a formula centred in the line, a replaced element
    /// standing on the baseline.
    private nonisolated func drawInlineImages(at point: CGPoint, in context: CGContext) {
        guard let ts = textStorage, let range = fragmentRange, range.length > 0 else { return }
        ts.enumerateAttribute(inlineImageAttribute, in: range, options: []) { value, attrRange, _ in
            guard let image = value as? PlatformImage, let cg = PlatformDraw.cgImage(image),
                  let line = lineFragment(forDocumentCharAt: attrRange.location),
                  let pos = charPosition(forDocumentCharAt: attrRange.location, point: point) else { return }
            let tb = line.typographicBounds
            let top: CGFloat
            if let drop = ts.attribute(inlineImageBaselineAttribute, at: attrRange.location,
                                       effectiveRange: nil) as? CGFloat {
                // `vertical-align: baseline` — the element's *bottom* edge is
                // the text baseline, which is what makes it grow the line box
                // upward. Measured against the inked baseline, not the reported
                // one: `glyphOrigin.y` has the paragraph's half-leading lift
                // already subtracted and the letters do not, so seating the
                // picture on the reported baseline left it hanging a
                // half-leading clear of the words either side of it.
                let baseline = point.y + tb.origin.y + line.glyphOrigin.y + drop
                top = baseline - image.size.height
            } else {
                // Inline maths: a phrase set in the middle of the line. The
                // concealed source char is near-zero-height, so the line is
                // what it is centred in, not the character's own font.
                top = point.y + tb.origin.y + tb.height / 2 - image.size.height / 2
            }
            let rect = CGRect(x: pos.x, y: top,
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

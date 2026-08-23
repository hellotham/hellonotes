//
//  GFMBoxMetrics.swift
//  MarkdownCore
//
//  GitHub's Markdown box model, as numbers — the *one* table both renderers
//  measure from.
//
//  HelloNotes draws the same document two ways: the live editor lays it out in
//  TextKit, and Preview lays it out in WebKit under github-markdown-css. Those
//  are different engines, so the only thing that can make them agree is a
//  shared set of numbers. They had none: the editor's type scale was
//  1.7/1.4/1.2/1.1/1/1 against the stylesheet's 2/1.5/1.25/1/.875/.85, its
//  line height was the system default against the stylesheet's 1.5, and it had
//  no inter-block spacing at all — the gap between two paragraphs was whatever
//  the blank line between them happened to measure. Switching Edit→Preview
//  therefore moved every line on the page.
//
//  So this type exists, and both sides read it: `EditorTheme`/`StyleApplier`
//  turn it into fonts and `NSParagraphStyle`s, and `GFMRenderer.page` emits it
//  as a CSS override block. Two consumers, one table. If a number here is
//  wrong both surfaces are wrong *together*, which is a bug you can see;
//  before, one surface was wrong alone, which is a bug you can only measure.
//
//  Everything scales with `base`. GitHub's stylesheet mixes `em` (which scale)
//  with `px` constants (which do not), so raising the app's Text Size grew the
//  type and left every margin at its 16px default — the layout got tighter as
//  the text got bigger. Here a margin is a multiple of `base` like everything
//  else, and the emitted CSS is absolute px computed from it, so the two
//  surfaces stay identical at every text size.
//

import Foundation
import CoreGraphics

public struct GFMBoxMetrics: Sendable, Equatable {

    /// The document's root font size — `.markdown-body { font-size }`, and the
    /// editor's body font. GitHub's own is 16.
    public let base: CGFloat

    public init(base: CGFloat = 16) {
        self.base = max(1, base)
    }

    /// GitHub's px constants are authored against a 16px root; every one of
    /// them is expressed here as a multiple of `base` so Text Size moves the
    /// whole layout, not just the glyphs.
    public var scale: CGFloat { base / 16 }

    // MARK: - Type scale

    /// `h1…h6 { font-size }` — 2em, 1.5em, 1.25em, 1em, .875em, .85em.
    public static let headingRatios: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]

    /// `.markdown-body { line-height: 1.5 }`.
    public static let bodyLineRatio: CGFloat = 1.5
    /// `h1…h6 { line-height: 1.25 }`.
    public static let headingLineRatio: CGFloat = 1.25
    /// `pre, code { font-size: 85% }`.
    public static let codeFontRatio: CGFloat = 0.85
    /// `pre { line-height: 1.45 }`.
    public static let codeLineRatio: CGFloat = 1.45
    /// `h1, h2 { padding-bottom: .3em }` — of the *heading's* size.
    public static let headingRulePadRatio: CGFloat = 0.3

    public func headingSize(_ level: Int) -> CGFloat {
        base * Self.headingRatios[max(1, min(6, level)) - 1]
    }

    /// Every line height is a **whole point**.
    ///
    /// Not for crispness — for agreement. WebKit does not use a fractional
    /// line height as given: `line-height: 19.72px` on a code block laid its
    /// lines out 19px apart, so a ten-line listing finished 7pt above where
    /// TextKit put it, and everything below the block inherited the error.
    /// Rounding here means both engines are handed an integer and there is
    /// nothing left to round. The cost is at most half a point against
    /// GitHub's own metrics, applied identically to both surfaces.
    public func headingLineHeight(_ level: Int) -> CGFloat {
        (headingSize(level) * Self.headingLineRatio).rounded()
    }

    public var bodyLineHeight: CGFloat { (base * Self.bodyLineRatio).rounded() }
    public var codeSize: CGFloat { base * Self.codeFontRatio }
    public var codeLineHeight: CGFloat { (codeSize * Self.codeLineRatio).rounded() }

    /// Space reserved under an h1/h2 for its bottom rule (`padding-bottom`
    /// plus the 1px border itself).
    public func headingRuleInset(_ level: Int) -> CGFloat {
        headingSize(level) * Self.headingRulePadRatio + hairline
    }

    // MARK: - Box model

    /// `--base-size-16`: the margin between sibling blocks.
    public var blockGap: CGFloat { 16 * scale }
    /// `--base-size-24`: `h1…h6 { margin-top }`.
    public var headingTopGap: CGFloat { 24 * scale }
    /// `ul, ol { padding-left: 2em }` — one nesting level.
    public var listIndent: CGFloat { 2 * base }
    /// `li + li { margin-top: .25em }`.
    public var listItemGap: CGFloat { 0.25 * base }
    /// `blockquote { padding: 0 1em }`.
    public var quotePadding: CGFloat { base }
    /// `blockquote { border-left: .25em }`.
    public var quoteBorder: CGFloat { 0.25 * base }
    /// Distance one blockquote nesting level moves its content right.
    public var quoteIndent: CGFloat { quoteBorder + quotePadding }
    /// `pre { padding: 16px }`.
    public var codePadding: CGFloat { 16 * scale }
    /// `pre, code { border-radius: 6px }`.
    public var codeRadius: CGFloat { 6 * scale }
    /// `code { padding: .2em .4em }` — of the *code* font size.
    public var inlineCodePadX: CGFloat { 0.4 * codeSize }
    public var inlineCodePadY: CGFloat { 0.2 * codeSize }
    /// `hr { height: .25em; margin: 24px 0 }`.
    public var ruleThickness: CGFloat { 0.25 * base }
    public var ruleGap: CGFloat { 24 * scale }
    /// `th, td { padding: 6px 13px }`.
    public var cellPadY: CGFloat { 6 * scale }
    public var cellPadX: CGFloat { 13 * scale }
    /// A 1px CSS border. Stays one point: a hairline is a hairline.
    public var hairline: CGFloat { 1 }

    // MARK: - Tables

    /// One row's content box: a line of the document's own text, plus the
    /// cell's vertical padding. A `<td>` inherits `line-height: 1.5` like
    /// everything else, so measuring the glyphs alone leaves every row short.
    public var tableRowHeight: CGFloat { bodyLineHeight + 2 * cellPadY }

    /// The height the page lays a table of `rows` rows out in — the header and
    /// the data rows; the delimiter line is a ruler and draws nothing.
    ///
    /// `table { border-collapse: collapse }`, and a collapsed border is a box
    /// of its own rather than ink inside the cell: N rows are separated and
    /// bounded by N+1 of them. The editor's grid was stroked *inside* the row
    /// heights, so every table it drew was exactly that many points shorter
    /// than the one Preview drew — 3pt on the two-row table that is the most
    /// common one there is, which reads as "close enough" right up until you
    /// put a table halfway down a long note.
    public func tableHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * tableRowHeight + CGFloat(rows + 1) * hairline
    }

    /// The width of a table whose columns' text measures `cellWidths`. Same
    /// rule on the other axis: the padding is inside each cell, and the
    /// collapsed verticals are `columns + 1` boxes between and around them.
    public func tableWidth(cellWidths: [CGFloat]) -> CGFloat {
        guard !cellWidths.isEmpty else { return 0 }
        return cellWidths.reduce(0) { $0 + $1 + 2 * cellPadX }
            + CGFloat(cellWidths.count + 1) * hairline
    }

    // MARK: - The gap model

    /// A block, named the way the stylesheet names it. The editor's parser has
    /// its own block vocabulary (`BlockKind`) which is finer — it splits a list
    /// into items and a heading into ATX/setext — so the mapping happens once,
    /// at the caller, and the spacing rules below only ever see CSS boxes.
    public enum Box: Sendable, Equatable {
        case paragraph
        case heading(level: Int)
        /// A list item. `lastInList` is the one that closes the list outright —
        /// an item that merely ends a *nested* list does not, because
        /// `ul ul { margin-bottom: 0 }`.
        case listItem(top: ListItemTop, lastInList: Bool)
        case codeBlock
        case quote
        case table
        case thematicBreak
        /// Front matter, **while the caret is inside it**. It has no GitHub
        /// equivalent — Preview strips it before cmark sees a byte of it — so
        /// folded it is not a box at all but unrendered source, and this shape
        /// is only what the raw YAML takes when the reader has opened it to
        /// edit. Paragraph-shaped, because that is what four lines of text
        /// want to look like. Used as the *folded* shape too, it reserved a
        /// paragraph's line for every property and a paragraph's margin under
        /// the lot, and the reader got a blank band where the note's title
        /// should have been.
        case frontMatter
        /// A raw HTML block. It has no margins of its own: `<div>` has none in
        /// any stylesheet, and an element that *does* — a `<table>`, a `<p>` —
        /// carries them inside the fragment the editor renders and measures.
        /// Giving it a paragraph's margin put 16pt around every bare wrapper.
        case htmlBlock
        /// A blockquote with nothing in it. `<blockquote></blockquote>` draws
        /// no content, and with nothing on its vertical axis to stop them its
        /// margins collapse straight through — so it is a box of no height and
        /// no margin, not a quoted line of text with 16pt either side.
        case emptyQuote
    }

    /// What sits above a list item, which is what decides its top margin.
    public enum ListItemTop: Sendable, Equatable {
        /// The first item of a list that is not nested inside another item:
        /// `ul { margin-top: 0 }`, and the margin above comes from whatever
        /// block precedes the list.
        case opensList
        /// The first item of a list nested inside another item. `ul ul` has no
        /// top margin of its own, so the space between the parent's text and
        /// the sub-list is a `<p>`'s margin escaping out of one side or the
        /// other: the parent item's own text is a `<p>` when *its* list is
        /// loose, and this item's text is a `<p>` when *this* list is. Either
        /// one puts 16pt there, which is why the flag is not `looseParent` —
        /// asking only the parent left every loose sub-list 16pt short of the
        /// page, and `- a` / `  - b` / blank / `    c` is the ordinary way to
        /// write one.
        case opensNestedList(spaced: Bool)
        /// Any other item: `li + li { margin-top: .25em }`, or in a loose list
        /// `li > p { margin-top: 16 }`.
        case sibling(loose: Bool)
    }

    /// `margin-top`, per the stylesheet.
    public func marginTop(_ box: Box) -> CGFloat {
        switch box {
        case .heading: headingTopGap
        case .thematicBreak: ruleGap
        // `p, blockquote, ul, ol, table, pre, details { margin-top: 0 }`.
        case .paragraph, .codeBlock, .quote, .table, .frontMatter, .htmlBlock, .emptyQuote: 0
        // Inside a list `ul { margin-top: 0 }`, and items are separated by
        // `li + li` (tight) or the `li > p` margin (loose).
        case .listItem(let top, _):
            switch top {
            case .opensList: 0
            case .opensNestedList(let loose): loose ? blockGap : 0
            case .sibling(let loose): loose ? blockGap : listItemGap
            }
        }
    }

    /// `margin-bottom`, per the stylesheet.
    public func marginBottom(_ box: Box) -> CGFloat {
        switch box {
        case .heading: blockGap
        case .thematicBreak: ruleGap
        case .paragraph, .codeBlock, .quote, .table, .frontMatter: blockGap
        // Whatever margin the element has is inside the rendered fragment.
        case .htmlBlock, .emptyQuote: 0
        // Only the last item carries the list's own bottom margin; between
        // items the gap is the next item's `margin-top` (see above).
        case .listItem(_, let last): last ? blockGap : 0
        }
    }

    /// The gap CSS actually leaves between two adjacent blocks.
    ///
    /// **Adjacent vertical margins collapse** — the space between a paragraph
    /// (`margin-bottom: 16`) and the heading after it (`margin-top: 24`) is 24,
    /// not 40. TextKit has no such rule: `paragraphSpacing` and
    /// `paragraphSpacingBefore` simply add. So the editor never sets both; it
    /// asks here for the one collapsed number and puts it below the first
    /// block. Getting this wrong is invisible in the common case (equal
    /// margins) and 8pt out at every heading, which is exactly the kind of
    /// drift that reads as "the preview is a different document".
    public func gap(after a: Box, before b: Box) -> CGFloat {
        max(marginBottom(a), marginTop(b))
    }

    // MARK: - CSS

    private static func px(_ v: CGFloat) -> String {
        // Trim to 4dp: enough that the two engines round to the same device
        // pixel, short enough to stay readable in a `view-source`.
        var s = String(format: "%.4f", Double(v))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "px"
    }

    /// The override block `GFMRenderer.page` appends after github-markdown-css,
    /// restating every metric above as an absolute px computed from `base`.
    ///
    /// Line heights are px too, not the stylesheet's unitless ratios. A ratio
    /// is resolved by the layout engine, and WebKit resolved `1.45` against a
    /// 13.6px code font as 19 rather than 19.72 — a 0.72pt error per line of
    /// code, which is invisible in a three-line block and 1.44pt by the second
    /// line. TextKit is being handed an exact number; the stylesheet gets the
    /// same exact number.
    ///
    /// Absolute, not `em`: a custom property holding `1.5em` resolves against
    /// whatever element *uses* it, so `--base-size-24` inside an h1 would come
    /// out 48px. The numbers have to be resolved on this side, where `base` is
    /// known, or the two surfaces stop agreeing exactly where the type gets big.
    public var css: String {
        let p = Self.px
        var out = """
        .markdown-body { font-size: \(p(base)); line-height: \(p(bodyLineHeight)); }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          margin-top: \(p(headingTopGap)); margin-bottom: \(p(blockGap));
        }
        """
        for level in 1...6 {
            out += "\n.markdown-body h\(level) { font-size: \(p(headingSize(level))); "
                + "line-height: \(p(headingLineHeight(level))); }"
        }
        for level in 1...2 {
            out += "\n.markdown-body h\(level) { padding-bottom: \(p(headingSize(level) * Self.headingRulePadRatio)); "
                + "border-bottom-width: \(p(hairline)); }"
        }
        out += """

        .markdown-body p, .markdown-body blockquote, .markdown-body ul, .markdown-body ol,
        .markdown-body dl, .markdown-body table, .markdown-body pre, .markdown-body details {
          margin-top: 0; margin-bottom: \(p(blockGap));
        }
        .markdown-body ul, .markdown-body ol { padding-left: \(p(listIndent)); }
        .markdown-body ul ul, .markdown-body ul ol,
        .markdown-body ol ol, .markdown-body ol ul { margin-top: 0; margin-bottom: 0; }
        .markdown-body li + li { margin-top: \(p(listItemGap)); }
        .markdown-body li > p { margin-top: \(p(blockGap)); }
        .markdown-body blockquote {
          padding: 0 \(p(quotePadding)); border-left-width: \(p(quoteBorder));
        }
        .markdown-body pre, .markdown-body .highlight pre {
          padding: \(p(codePadding)); font-size: \(p(codeSize));
          line-height: \(p(codeLineHeight)); border-radius: \(p(codeRadius));
        }
        /* A code line longer than the column **wraps**; it does not scroll.
           GitHub gives `pre` `overflow: auto` and lets a long line run off the
           side of a fixed column, and TextKit has no equivalent — a text view's
           container tracks the pane's width, so the editor wraps and always
           has. Left as GitHub has it the same note is two documents: every code
           line over about eighty characters is one line tall in Preview and two
           in Edit, which is 20pt a line and compounds down a README. The corpus
           cannot see it, because no example in it has a code line long enough
           to wrap at any width the sweep uses; a four-line Swift snippet out of
           a real note does, immediately.
           `break-word`, not `anywhere`, because that is TextKit's rule as well:
           break between words, and inside a word only when the word by itself
           will not fit the line.
           `pre > code` has to be named as well as `pre`: `white-space` inherits,
           but github-markdown-css sets `white-space: pre` on `.markdown-body
           pre>code` directly, and an inherited value never beats a declared
           one however specific its ancestor's is. Setting only `pre` measured
           as a no-op and read exactly like a rule that had not been reached. */
        .markdown-body pre, .markdown-body pre > code, .markdown-body pre > tt {
          white-space: pre-wrap; overflow-wrap: break-word;
        }
        .markdown-body code, .markdown-body tt {
          font-size: \(p(codeSize)); padding: \(p(inlineCodePadY)) \(p(inlineCodePadX));
          border-radius: \(p(codeRadius));
        }
        /* An inline `code` span is set in a different family at a different
           size, and WebKit sizes a line box to fit every inline box in it — so
           a paragraph containing one came out a point taller than the same
           paragraph without. TextKit pins the line height instead, so the two
           disagreed on any line with code in it. Pinning the span's own line
           box below the strut's leaves the paragraph's line height to the
           paragraph, which is what both engines then agree on. */
        .markdown-body p code, .markdown-body li code, .markdown-body blockquote code,
        .markdown-body td code, .markdown-body th code, .markdown-body p tt {
          line-height: 1;
        }
        /* …and this rule has to come *after* that one. `li code` and `pre code`
           have identical specificity, so source order alone decides which wins
           for the `<code>` of a fenced block inside a list item — and with the
           inline rule last it did, pinning that code to `line-height: 1`.
           The corpus could not see it: every fenced-in-a-list example it has
           puts the fence first in the item, where the marker sits in that line
           box and is taller than either value. A code block written *under* an
           item's text — `1. Install:` then an indented ```bash block, i.e. every
           README ever — has no marker in it, and there the block came out 7pt
           short of the editor's. Measured before and after with
           `PARITY_CSS=line-height`. Reverted once as a no-op on the strength of
           the corpus alone, which is the lesson: 672 single constructs are not
           the same thing as the documents people write. */
        .markdown-body pre code, .markdown-body pre tt {
          font-size: inherit; padding: 0; line-height: inherit;
        }
        /* cmark-gfm emits a bare `<input type=checkbox>` with none of the
           classes github.com's own pipeline adds, so the rule that pulls the
           box out into the list's gutter never matched and the item's text
           started a checkbox-width right of every other list item's. */
        .markdown-body li { position: relative; }
        .markdown-body li > input[type="checkbox"]:first-child {
          position: absolute; left: -1.4em; top: .3em; margin: 0;
        }
        .markdown-body hr { height: \(p(ruleThickness)); margin: \(p(ruleGap)) 0; border: 0; }
        .markdown-body table th, .markdown-body table td {
          padding: \(p(cellPadY)) \(p(cellPadX)); border-width: \(p(hairline));
        }
        """
        return out
    }
}

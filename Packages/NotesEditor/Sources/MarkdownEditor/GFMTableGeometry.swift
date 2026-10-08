//
//  GFMTableGeometry.swift
//  MarkdownEditor
//
//  Where a rendered table's grid lines go — measured once, for everyone who
//  needs the answer.
//
//  The editor replaces a table's source with a picture of it, and the app is
//  what draws that picture. That split is why the corpus never measured a
//  table: with no renderer in the package the parity sweep laid the *source*
//  out — four lines of pipes against a three-row grid — and reported the
//  difference as a spacing bug. Two sections of the GFM specification were
//  therefore graded on a comparison that could not have passed.
//
//  So the geometry moves here, where both sides can reach it, and the *size* of
//  what is drawn comes from `GFMTableLayout` and `GFMBoxMetrics`, exactly as the
//  Preview's `<table>` does. A harness that cannot draw a table can still ask
//  how big one is.
//
//  So does *what* is drawn. A cell is Markdown — `| Ask Library (**⇧⌘J**) |` —
//  and it was measured from its source and drawn from its source, asterisks
//  and all, beside a Preview showing "Ask Library (⇧⌘J)" with the keys in
//  semibold. Each cell is now its text as the page renders it (`cellText`),
//  broken into lines here (`lineRanges`), and `GFMTableImage` draws exactly
//  those lines: a grid measured from one reading of a cell and drawn from
//  another is a grid whose lines run through its own text.
//

import CoreGraphics
import CoreText
import Foundation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The measured grid for one table: column widths, row height, total size.
public struct GFMTableGrid: Sendable {
    public let table: GFMTableLayout
    /// Per column, the *content* width — the cell's padding and the collapsed
    /// borders are added by `naturalSize`, so a renderer drawing the grid adds
    /// them once, in the same place, on both axes.
    public let columnTextWidths: [CGFloat]
    /// Every row is the same height: one line of body text plus `td` padding —
    /// until a cell wraps, which only happens once the table is squeezed. See
    /// `rowHeights`.
    public let rowHeight: CGFloat
    /// Each row's own height. Equal to `rowHeight` throughout for a table that
    /// fits; taller for a row whose cells wrapped.
    public let rowHeights: [CGFloat]
    /// The size the grid wants, before it is fitted to the pane.
    public let naturalSize: CGSize
    /// The fonts the widths above were measured in. Handed to the renderer
    /// rather than looked up again there: a grid measured in one font and
    /// drawn in another is a grid whose lines run through its own text.
    public let bodyFont: PlatformFont
    public let headerFont: PlatformFont

    /// Each cell's text as the page renders it — no markers, bold and code in
    /// their own faces (`GFMTableGeometry.cellText`). The widths above were
    /// measured from exactly these, and `GFMTableImage` draws exactly these.
    public let cells: [[NSAttributedString]]
    /// Where each cell's lines break, as ranges of its text in `cells`: one line
    /// holding the whole cell in a table that fits, more in a cell that wrapped
    /// once its column was squeezed. `rowHeights` were counted from these, so
    /// the lines drawn and the height reserved for them cannot disagree.
    public let cellLines: [[[NSRange]]]

    /// The font row `r` is set in — `th { font-weight: 600 }` for the header.
    public func font(row r: Int) -> PlatformFont { r == 0 ? headerFont : bodyFont }

    public var rowCount: Int { table.rowCount }
    public var columnCount: Int { table.columnCount }
    public var alignments: [GFMTableLayout.Alignment] { table.alignments }
    public var rows: [[String]] { table.rows }
}

public enum GFMTableGeometry {

    /// Measure `source` in `theme`'s fonts, or nil when it is not a table.
    ///
    /// `nonisolated` and font-only: no drawing context, no view, nothing that
    /// has to be on the main actor — so the sweep can ask for a table's size
    /// from wherever it happens to be measuring.
    public static func grid(source: String, theme: EditorTheme) -> GFMTableGrid? {
        guard let table = GFMTableLayout(source: source) else { return nil }
        let m = theme.metrics
        var widths = [CGFloat](repeating: 0, count: table.columnCount)
        var cells: [[NSAttributedString]] = []
        var cellLines: [[[NSRange]]] = []
        var heights: [CGFloat] = []
        for (r, row) in table.rows.enumerated() {
            // `th { font-weight: 600 }` — the header row is set semibold, and
            // semibold is wider, so measuring it in the body font puts the
            // grid line through the last letter of the widest heading.
            let font = r == 0 ? theme.bodyBold : theme.body
            let texts = row.prefix(widths.count).map { cellText($0, font: font, theme: theme) }
            // Unsqueezed, a cell breaks only where it says so (`<br>`); a column
            // is as wide as the longest of its lines, and a row as tall as its
            // cell with the most of them.
            let lines = texts.map { lineRanges($0, width: .infinity) }
            for (c, text) in texts.enumerated() {
                let string = text.string as NSString
                for line in lines[c] {
                    let shown = text.attributedSubstring(from: hangingSpaceTrimmed(line, in: string))
                    widths[c] = max(widths[c], shown.size().width.rounded(.up))
                }
            }
            let tallest = max(1, lines.map(\.count).max() ?? 1)
            heights.append(CGFloat(tallest) * m.bodyLineHeight + 2 * m.cellPadY)
            cells.append(texts)
            cellLines.append(lines)
        }
        return GFMTableGrid(
            table: table,
            columnTextWidths: widths,
            rowHeight: m.tableRowHeight,
            rowHeights: heights,
            naturalSize: CGSize(width: m.tableWidth(cellWidths: widths),
                                height: heights.reduce(0, +) + CGFloat(table.rowCount + 1) * m.hairline),
            bodyFont: theme.body, headerFont: theme.bodyBold,
            cells: cells,
            cellLines: cellLines)
    }

    /// The grid as it is actually laid out inside `maxWidth`: the column widths
    /// after shrinking, and each row's own height once its cells have wrapped.
    ///
    /// A table too wide for its pane does **not** scale. A browser shrinks the
    /// columns and the cell text wraps, so the table gets *taller*; the editor
    /// used to scale the whole bitmap down, so it got *shorter*. The two moved
    /// in opposite directions and the error grew with how badly the table
    /// overflowed — 27pt on a four-column table at a 420pt pane, 84pt on a
    /// wider one. Every table in the spec corpus fits at the sweep's 800pt,
    /// which is why 672 examples agreed while a README did not.
    ///
    /// The distribution is WebKit's auto table layout (`AutoTableLayout`),
    /// which lays the Preview's `<table>` out: GitHub's stylesheet makes an
    /// over-wide table exactly as wide as the pane (`display: block; width:
    /// max-content; max-width: 100%`), every column starts at the width it
    /// *needs* (its longest word, which cannot break), and then the whole width
    /// — the minimums included — is shared out in proportion to what each column
    /// *wants* (its longest cell, unwrapped), left to right, none going below
    /// its minimum; an overshoot is taken back from the last columns first. A
    /// column's two widths are its box's, padding and border included, as a
    /// cell's preferred widths are. It used to share only the space *above* the
    /// minimums, in proportion to how much each could give — a different rule
    /// that gave a table of long cells a wider first column than the page does,
    /// so two of its rows wrapped in Preview and not in Edit, 48pt at 560pt.
    /// When even the minimums do not fit, they are used and the table overflows
    /// — which is what a browser does too.
    public static func fitted(source: String, theme: EditorTheme,
                              maxWidth: CGFloat) -> GFMTableGrid? {
        guard let grid = grid(source: source, theme: theme) else { return nil }
        let m = theme.metrics
        guard grid.naturalSize.width > maxWidth, maxWidth > 0 else { return grid }

        let wants = grid.columnTextWidths
        var needs = [CGFloat](repeating: 0, count: grid.columnCount)
        for row in grid.cells {
            for (c, text) in row.enumerated() where c < needs.count {
                // A piece carries whatever code padding falls in it — the
                // leading pad on the piece a code span starts in, the trailing
                // one on the piece it ends in — which is where the page puts
                // them, rather than every piece paying for all of it.
                // A piece's trailing space hangs, as it does on the page: the
                // narrowest a column can be is its longest *word*. Counting the
                // space made the first column of a table of long cells a space
                // wider than the page's, and at 420pt its neighbour wrapped a
                // line the page does not.
                let whole = text.string as NSString
                var from = 0
                for i in 0..<whole.length {
                    guard breaksAfter(whole.character(at: i)) || i == whole.length - 1 else { continue }
                    let piece = hangingSpaceTrimmed(NSRange(location: from, length: i + 1 - from), in: whole)
                    let w = text.attributedSubstring(from: piece).size().width
                    needs[c] = max(needs[c], w.rounded(.up))
                    from = i + 1
                }
            }
        }
        // What a column's box adds to its text: two paddings and a border. The
        // border that closes the last column belongs to the table.
        let chrome = 2 * m.cellPadX + m.hairline
        let mins = needs.map { $0 + chrome }, maxes = wants.map { $0 + chrome }
        var boxes = mins
        var available = maxWidth - m.hairline - mins.reduce(0, +)
        if available > 0 {
            available += mins.reduce(0, +)
            var wanted = maxes.reduce(0, +)
            for c in boxes.indices where wanted > 0 {
                boxes[c] = max(mins[c], available * maxes[c] / wanted)
                available -= boxes[c]
                wanted -= maxes[c]
            }
            if available < 0 {
                var aboveMinimum = boxes.indices.reduce(CGFloat(0)) { $0 + boxes[$1] - mins[$1] }
                for c in boxes.indices.reversed() where aboveMinimum > 0 {
                    let above = boxes[c] - mins[c]
                    let reduce = available * above / aboveMinimum
                    boxes[c] += reduce
                    available -= reduce
                    aboveMinimum -= above
                    if available >= 0 { break }
                }
            }
        }
        let fittedWidths = boxes.map { $0 - chrome }

        // Each row is as tall as its tallest cell once that cell has wrapped —
        // and the lines it wrapped into are kept, because they are what is drawn.
        var heights: [CGFloat] = []
        var cellLines: [[[NSRange]]] = []
        for row in grid.cells {
            let lines = row.enumerated().map { c, text in
                c < fittedWidths.count ? lineRanges(text, width: fittedWidths[c])
                    : [NSRange(location: 0, length: text.length)]
            }
            let tallest = max(1, lines.map(\.count).max() ?? 1)
            heights.append(CGFloat(tallest) * m.bodyLineHeight + 2 * m.cellPadY)
            cellLines.append(lines)
        }
        let height = heights.reduce(0, +) + CGFloat(grid.rowCount + 1) * m.hairline
        return GFMTableGrid(
            table: grid.table,
            columnTextWidths: fittedWidths,
            rowHeight: m.tableRowHeight,
            rowHeights: heights,
            naturalSize: CGSize(width: m.tableWidth(cellWidths: fittedWidths), height: height),
            bodyFont: grid.bodyFont, headerFont: grid.headerFont,
            cells: grid.cells, cellLines: cellLines)
    }


    /// A cell's text as the page draws it, not as the writer typed it.
    ///
    /// `| Ask Library (**⇧⌘J**) |` is "Ask Library (⇧⌘J)" with the keys in the
    /// semibold the page gives `strong`; a link is its label in the link
    /// colour, a wiki link its alias, `~~x~~` struck through, `` `--port` ``
    /// monospaced at `code`'s 85% inside `code`'s padding. The cell is read by
    /// the editor's own inline pass — `StyleSpec.inlineRuns`, the very runs it
    /// lays over this cell while the table's source is showing — and set by the
    /// editor's own mapping from a role to fonts and colours
    /// (`StyleApplier.apply`), caret-away. So a cell reads as the same text does
    /// anywhere else in the note, and there is no second parser to disagree
    /// with the first.
    ///
    /// What the editor conceals when the caret is elsewhere is **not drawn at
    /// all** here, rather than shrunk: a picture has no caret to reveal it for,
    /// and a concealed marker keeps a sliver of advance — a link's destination
    /// adds up — and its `/`s and spaces would be places to break a line the
    /// page never breaks.
    ///
    /// Code's horizontal padding stays in the text as kerning, which is what
    /// makes every measurement of the cell see it: after the code's last
    /// character (where the editor's styling puts it), and before its first on
    /// a no-break space too small to see, standing where the opening backticks
    /// were (`codePaddingAttribute`) — kerning on a zero-width space is dropped.
    /// `inlineCodeAttribute` stays on the code, for its pill.
    ///
    /// Measuring the source instead counted characters that are never drawn,
    /// in the wrong face: invisible at any width where the table fits, and one
    /// wrapped line per cell at any width where it does not.
    ///
    /// Raw inline HTML is the one thing drawn differently from the editor's own
    /// caret-away styling, because the page draws it differently: Edit leaves
    /// a tag on screen as the source it is, and the page never draws a tag. So
    /// a tag is not drawn here either — `<br>` is the line break it makes
    /// (`lineSeparator`), and any other tag is just markup around text that is
    /// drawn as text. `H<sub>2</sub>O` is "H2O", not eleven characters of
    /// source; the subscript's size is a style this picture does not attempt.
    ///
    /// And every figure is tabular — `table { font-variant: tabular-nums }` in
    /// GitHub's stylesheet — so a column of numbers is as wide here as there.
    static func cellText(_ cell: String, font: PlatformFont, theme: EditorTheme) -> NSAttributedString {
        let ns = cell as NSString
        let all = NSRange(location: 0, length: ns.length)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.text]
        let runs = StyleSpec.inlineRuns(in: all, text: ns)
        let tags = rawTags(in: ns)
        guard !runs.isEmpty || !tags.isEmpty else {
            return withTabularFigures(NSAttributedString(string: cell, attributes: base))
        }

        let source = NSMutableAttributedString(string: cell, attributes: base)
        for run in runs {
            StyleApplier.apply(run, to: source, theme: theme, revealed: false, resolveWiki: nil)
        }
        var hidden = [Bool](repeating: false, count: ns.length)
        for run in runs where run.role == .marker && run.concealment == .whenInactive {
            for i in run.range.location..<min(NSMaxRange(run.range), ns.length) { hidden[i] = true }
        }
        // A tag is drawn as nothing — a `<br>` as the break it makes, standing
        // where the tag started.
        var breaks = Set<Int>()
        for tag in tags {
            for i in tag.location..<min(NSMaxRange(tag), ns.length) { hidden[i] = true }
            if isLineBreak(ns.substring(with: tag)) { breaks.insert(tag.location) }
        }
        // The last character of each code span's opening run carries its
        // leading padding (`StyleApplier`'s `.inlineCode`); it becomes the carrier.
        var carriers = Set<Int>()
        for run in runs where run.role == .inlineCode {
            let before = run.range.location - 1
            if before >= 0, hidden[before] { carriers.insert(before) }
        }

        let out = NSMutableAttributedString()
        var i = 0
        while i < ns.length {
            if breaks.contains(i) {
                out.append(NSAttributedString(string: String(utf16CodeUnits: [lineSeparator], count: 1),
                                              attributes: source.attributes(at: i, effectiveRange: nil)))
            }
            if carriers.contains(i) {
                var attributes = source.attributes(at: i, effectiveRange: nil)
                let pad = attributes[.kern] as? CGFloat ?? 0
                attributes[.kern] = pad - Self.carrierAdvance(theme)
                attributes[codePaddingAttribute] = pad
                out.append(NSAttributedString(string: "\u{00A0}", attributes: attributes))
                i += 1
            } else if hidden[i] {
                i += 1
            } else {
                var j = i + 1
                while j < ns.length, !hidden[j], !carriers.contains(j), !breaks.contains(j) { j += 1 }
                out.append(source.attributedSubstring(from: NSRange(location: i, length: j - i)))
                i = j
            }
        }
        // A picture is not a link: nothing to click, and no platform's link
        // styling to borrow.
        out.removeAttribute(.link, range: NSRange(location: 0, length: out.length))
        return withTabularFigures(out)
    }

    /// The character a `<br>` becomes: a line break inside the cell's one
    /// paragraph. `lineRanges` ends a line on it, and it is never drawn
    /// (`hangingSpaceTrimmed` takes it off the line it ends).
    static let lineSeparator: unichar = 0x2028

    /// Every raw inline tag in `cell` — at the top level, and inside a link's
    /// text, where the parser leaves the text unparsed — as source ranges.
    private static func rawTags(in cell: NSString) -> [NSRange] {
        var tags: [NSRange] = []
        for node in InlineParser.parse(cell, in: NSRange(location: 0, length: cell.length)) {
            if case .rawHTML = node.kind { tags.append(node.range) }
            guard case .link = node.kind, node.contentRange.length > 0 else { continue }
            for inner in InlineParser.parse(cell, in: node.contentRange) {
                if case .rawHTML = inner.kind { tags.append(inner.range) }
            }
        }
        return tags
    }

    /// `<br>`, `<br/>`, `<br />`, in any case, with or without attributes.
    private static func isLineBreak(_ tag: String) -> Bool {
        var t = Substring(tag.lowercased())
        guard t.hasPrefix("<br"), t.hasSuffix(">") else { return false }
        t = t.dropFirst(3).dropLast()
        if t.hasSuffix("/") { t = t.dropLast() }
        return t.isEmpty || t.first?.isWhitespace == true
    }

    /// `font` with tabular figures — `font-variant: tabular-nums`, which
    /// GitHub's stylesheet sets on every table: each figure as wide as every
    /// other, so a column of numbers lines up and measures what the page's does.
    public static func tabularFigures(_ font: PlatformFont) -> PlatformFont {
        #if canImport(AppKit)
        let setting: [NSFontDescriptor.FeatureKey: Int] =
            [.typeIdentifier: kNumberSpacingType, .selectorIdentifier: kMonospacedNumbersSelector]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [setting]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #else
        let setting: [UIFontDescriptor.FeatureKey: Int] =
            [.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [setting]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    /// Every font in `text` with tabular figures.
    private static func withTabularFigures(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            if let font = value as? PlatformFont {
                out.addAttribute(.font, value: tabularFigures(font), range: range)
            }
        }
        return out
    }

    /// Marks the carrier in front of a code span, with the padding it stands for.
    static let codePaddingAttribute = NSAttributedString.Key("hn.tableCodePadding")

    /// The carrier's own advance, which its kerning gives back so that the
    /// carrier is exactly the padding wide.
    private static func carrierAdvance(_ theme: EditorTheme) -> CGFloat {
        NSAttributedString(string: "\u{00A0}", attributes: [.font: theme.concealed]).size().width
    }

    /// How many lines `text` takes at `width` in `font`. Greedy, on spaces,
    /// which is what a line breaker does for text with no other break
    /// opportunities in it — and a table cell is short enough that the
    /// difference from a full Knuth pass is a cell that is one word wider,
    /// not a row that is a line taller.
    static func wrappedLineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        lineRanges(text, width: width).count
    }

    /// Where `text` breaks at `width`: the ranges of its lines, first to last.
    ///
    /// The same greedy decisions `wrappedLineCount` has always counted — it
    /// counts these now — kept as ranges, because the picture draws these lines
    /// and a renderer left to wrap the cell by itself (`draw(in:)` did) breaks
    /// where *its* breaker likes and at its own line height. A line keeps the
    /// break character it ended on; a drawer trims trailing spaces, which CSS
    /// hangs.
    ///
    /// A `<br>` (`lineSeparator`) ends a line wherever it stands, and each run
    /// between two of them wraps on its own. One that ends the cell starts no
    /// line after it, as a trailing `<br>` starts none on the page.
    static func lineRanges(_ text: NSAttributedString, width: CGFloat) -> [NSRange] {
        let whole = text.string as NSString
        var lines: [NSRange] = []
        var start = 0
        while true {
            var end = start
            while end < whole.length, whole.character(at: end) != lineSeparator { end += 1 }
            var wrapped = wrap(text, NSRange(location: start, length: end - start), width: width)
            guard end < whole.length else { return lines + wrapped }
            // The line keeps the break it ended on, so the lines tile the text.
            wrapped[wrapped.count - 1].length += 1
            lines += wrapped
            start = end + 1
            if start == whole.length { return lines }
        }
    }

    /// The greedy breaking of one run of `text` with no forced break in it.
    private static func wrap(_ text: NSAttributedString, _ run: NSRange, width: CGFloat) -> [NSRange] {
        let whole = text.string as NSString
        /// Whether `range` fits — without the spaces it ends on, which hang.
        func fits(_ range: NSRange) -> Bool {
            text.attributedSubstring(from: hangingSpaceTrimmed(range, in: whole)).size().width <= width
        }
        guard width > 0, width.isFinite, !fits(run) else { return [run] }
        var lines: [NSRange] = []
        var lineStart = run.location, lastBreak = run.location - 1
        for i in run.location..<NSMaxRange(run) {
            guard breaksAfter(whole.character(at: i)) else { continue }
            let candidate = NSRange(location: lineStart, length: i + 1 - lineStart)
            if !fits(candidate), lastBreak >= lineStart {
                lines.append(NSRange(location: lineStart, length: lastBreak + 1 - lineStart))
                lineStart = lastBreak + 1
            }
            lastBreak = i
        }
        let tail = NSRange(location: lineStart, length: NSMaxRange(run) - lineStart)
        if tail.length > 0, !fits(tail), lastBreak >= lineStart {
            lines.append(NSRange(location: lineStart, length: lastBreak + 1 - lineStart))
            lineStart = lastBreak + 1
        }
        lines.append(NSRange(location: lineStart, length: NSMaxRange(run) - lineStart))
        return lines
    }

    /// `range` without the spaces it ends on. CSS hangs a line's trailing
    /// white space: it neither counts towards whether the line fits nor towards
    /// the narrowest a column can be, and a right- or centre-aligned line lines
    /// up on its last glyph.
    ///
    /// The `<br>` a line ended on comes off with them: a break is not drawn.
    static func hangingSpaceTrimmed(_ range: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(range)
        if end > range.location, string.character(at: end - 1) == lineSeparator { end -= 1 }
        while end > range.location {
            let c = string.character(at: end - 1)
            guard c == 0x20 || c == 0x09 else { break }
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    /// Whether a line may break *after* this character.
    ///
    /// Spaces, and — this is the part that matters — a hyphen or a solidus.
    /// UAX #14 makes both a break opportunity and WebKit takes them, so a
    /// `--watch` in a narrow table cell is two lines on the page. Treating a
    /// cell as breakable only at spaces made that column demand more width
    /// than the page gives it, and the row came out a line short. The editor
    /// does its own line breaking inside a table — it draws a picture of one —
    /// so here the two can be made to agree exactly rather than approximately.
    private static func breaksAfter(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x2D || c == 0x2F || c == lineSeparator
    }

    /// String convenience, for callers that have no styled run to hand.
    static func wrappedLineCount(_ text: String, font: PlatformFont, width: CGFloat) -> Int {
        wrappedLineCount(NSAttributedString(string: text, attributes: [.font: font]), width: width)
    }

    /// The size the grid is actually drawn at inside `maxWidth`.
    public static func fittedSize(source: String, theme: EditorTheme,
                                  maxWidth: CGFloat) -> CGSize? {
        fitted(source: source, theme: theme, maxWidth: maxWidth)?.naturalSize
    }
}

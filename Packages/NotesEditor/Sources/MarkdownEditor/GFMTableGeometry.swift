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
//  So the geometry moves here, where both sides can reach it: the drawing stays
//  in the app (it is pixels, and the app owns pixels), and the *size* of what
//  it draws comes from `GFMTableLayout` and `GFMBoxMetrics`, exactly as the
//  Preview's `<table>` does. A harness that cannot draw a table can still ask
//  how big one is.
//

import CoreGraphics
import Foundation
import MarkdownCore

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
        for (r, row) in table.rows.enumerated() {
            // `th { font-weight: 600 }` — the header row is set semibold, and
            // semibold is wider, so measuring it in the body font puts the
            // grid line through the last letter of the widest heading.
            let font = r == 0 ? theme.bodyBold : theme.body
            for (c, cell) in row.enumerated() where c < widths.count {
                let drawn = cellText(cell, font: font, theme: theme)
                let size = drawn.text.size()
                widths[c] = max(widths[c], (size.width + drawn.padding).rounded(.up))
            }
        }
        return GFMTableGrid(
            table: table,
            columnTextWidths: widths,
            rowHeight: m.tableRowHeight,
            rowHeights: Array(repeating: m.tableRowHeight, count: table.rowCount),
            naturalSize: CGSize(width: m.tableWidth(cellWidths: widths),
                                height: m.tableHeight(rows: table.rowCount)),
            bodyFont: theme.body, headerFont: theme.bodyBold)
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
    /// The distribution is CSS's, reduced to its two bounds: a column can give
    /// up the space between the width it *wants* (its longest cell, unwrapped)
    /// and the width it *needs* (its longest single word, which cannot break),
    /// and the deficit is shared out in proportion to how much each has to
    /// give. When even the minimums do not fit, they are used and the table
    /// overflows — which is what a browser does too.
    public static func fitted(source: String, theme: EditorTheme,
                              maxWidth: CGFloat) -> GFMTableGrid? {
        guard let grid = grid(source: source, theme: theme) else { return nil }
        let m = theme.metrics
        guard grid.naturalSize.width > maxWidth, maxWidth > 0 else { return grid }

        // Chrome the text does not get: two paddings and a border per column,
        // plus the border that closes the last one.
        let chrome = CGFloat(grid.columnCount) * (2 * m.cellPadX + m.hairline) + m.hairline
        let available = maxWidth - chrome
        let wants = grid.columnTextWidths
        var needs = [CGFloat](repeating: 0, count: grid.columnCount)
        for (r, row) in grid.table.rows.enumerated() {
            let font = grid.font(row: r)
            for (c, cell) in row.enumerated() where c < needs.count {
                let drawn = cellText(cell, font: font, theme: theme)
                let whole = drawn.text.string as NSString
                var from = 0
                for i in 0..<whole.length {
                    guard breaksAfter(whole.character(at: i)) || i == whole.length - 1 else { continue }
                    let piece = NSRange(location: from, length: i + 1 - from)
                    let w = drawn.text.attributedSubstring(from: piece).size().width
                    needs[c] = max(needs[c], (w + drawn.padding).rounded(.up))
                    from = i + 1
                }
            }
        }
        let totalNeeds = needs.reduce(0, +), totalWants = wants.reduce(0, +)
        var fittedWidths = needs
        if available > totalNeeds, totalWants > totalNeeds {
            let slack = available - totalNeeds
            let give = totalWants - totalNeeds
            for c in fittedWidths.indices {
                fittedWidths[c] = needs[c] + (wants[c] - needs[c]) / give * slack
            }
        }

        // Each row is as tall as its tallest cell once that cell has wrapped.
        var heights: [CGFloat] = []
        for (r, row) in grid.table.rows.enumerated() {
            let font = grid.font(row: r)
            var lines = 1
            for (c, cell) in row.enumerated() where c < fittedWidths.count {
                let drawn = cellText(cell, font: font, theme: theme)
                lines = max(lines, wrappedLineCount(drawn.text,
                                                    width: fittedWidths[c] - drawn.padding))
            }
            heights.append(CGFloat(lines) * m.bodyLineHeight + 2 * m.cellPadY)
            _ = r
        }
        let height = heights.reduce(0, +) + CGFloat(grid.rowCount + 1) * m.hairline
        return GFMTableGrid(
            table: grid.table,
            columnTextWidths: fittedWidths,
            rowHeight: m.tableRowHeight,
            rowHeights: heights,
            naturalSize: CGSize(width: m.tableWidth(cellWidths: fittedWidths), height: height),
            bodyFont: grid.bodyFont, headerFont: grid.headerFont)
    }


    /// A cell's text as the page draws it, not as the writer typed it.
    ///
    /// `| `--port` | 8080 |` is measured here the way `<td><code>--port</code></td>`
    /// is laid out: the backticks are delimiters and disappear, and what is
    /// between them is set in the monospace face at `code`'s 85%, inside
    /// `code`'s horizontal padding. Measuring the raw source in the body font
    /// instead counts two characters that are never drawn and sets the rest in
    /// the wrong face — which is invisible at any width where the table fits,
    /// and one wrapped line per cell at any width where it does not.
    static func cellText(_ cell: String, font: PlatformFont,
                         theme: EditorTheme) -> (text: NSAttributedString, padding: CGFloat) {
        guard cell.contains("`") else {
            return (NSAttributedString(string: cell, attributes: [.font: font]), 0)
        }
        let m = theme.metrics
        let out = NSMutableAttributedString()
        var padding: CGFloat = 0
        var rest = Substring(cell)
        while let open = rest.firstIndex(of: "`") {
            // A span is closed by a run of backticks the same length as the one
            // that opened it; an unclosed run is literal text, as it is in the
            // inline parser.
            var ticks = 0
            var i = open
            while i < rest.endIndex, rest[i] == "`" { ticks += 1; i = rest.index(after: i) }
            let fence = String(repeating: "`", count: ticks)
            guard let close = rest[i...].range(of: fence) else { break }
            out.append(NSAttributedString(string: String(rest[..<open]), attributes: [.font: font]))
            out.append(NSAttributedString(string: String(rest[i..<close.lowerBound]),
                                          attributes: [.font: theme.mono]))
            padding += 2 * m.inlineCodePadX
            rest = rest[close.upperBound...]
        }
        out.append(NSAttributedString(string: String(rest), attributes: [.font: font]))
        return (out, padding)
    }

    /// How many lines `text` takes at `width` in `font`. Greedy, on spaces,
    /// which is what a line breaker does for text with no other break
    /// opportunities in it — and a table cell is short enough that the
    /// difference from a full Knuth pass is a cell that is one word wider,
    /// not a row that is a line taller.
    static func wrappedLineCount(_ text: NSAttributedString, width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        if text.size().width <= width { return 1 }
        let whole = text.string as NSString
        var lines = 1, lineStart = 0, lastBreak = -1
        for i in 0..<whole.length {
            guard breaksAfter(whole.character(at: i)) else { continue }
            let candidate = NSRange(location: lineStart, length: i + 1 - lineStart)
            if text.attributedSubstring(from: candidate).size().width > width, lastBreak >= lineStart {
                lines += 1
                lineStart = lastBreak + 1
            }
            lastBreak = i
        }
        let tail = NSRange(location: lineStart, length: whole.length - lineStart)
        if tail.length > 0, text.attributedSubstring(from: tail).size().width > width,
           lastBreak >= lineStart {
            lines += 1
        }
        return lines
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
        c == 0x20 || c == 0x09 || c == 0x2D || c == 0x2F
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

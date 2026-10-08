//
//  GFMTableLayout.swift
//  MarkdownCore
//
//  A GFM pipe table, read as a grid: which cells, in which columns, aligned
//  which way — and, with `GFMBoxMetrics`, how tall the grid is.
//
//  The editor draws a table as a rendered image in place of its source, so a
//  table is the one construct where Edit and Preview are not even the same kind
//  of thing: one is a bitmap, the other is a `<table>`. They can only agree if
//  the bitmap is *measured* the way the `<table>` is, which means the row count
//  and the row height have to come from one place rather than from whatever the
//  renderer happened to do with the lines it was handed.
//
//  Two things the renderer used to get wrong, both of them structural:
//
//  * **The delimiter line is a ruler, not a row.** `| --- | --- |` sets the
//    columns' alignment and draws nothing. Counting it made every table one row
//    taller than the page's — and because the editor was measured against its
//    own *source lines* rather than against the picture it draws, four lines of
//    pipes scored as three rendered rows and the error read as a 16pt shortfall
//    somewhere else entirely.
//  * **A pipe can be escaped.** `| f\|oo |` is one cell holding `f|oo`, not two
//    cells; splitting on every `|` invented a column, and an invented column is
//    a different width, a different natural size and a different scale factor.
//

import Foundation
import CoreGraphics

/// The grid a GFM pipe table describes.
public struct GFMTableLayout: Sendable, Equatable {

    /// `| :-- | :-: | --: |` — the delimiter cell's colons.
    public enum Alignment: Sendable, Equatable {
        case left, center, right
    }

    /// The header row first, then the data rows. The delimiter line is not
    /// here: it is the thing that *describes* the columns.
    public let rows: [[String]]
    /// One per column, from the delimiter line. Short rows are left-aligned.
    public let alignments: [Alignment]
    /// One per column, as the delimiter line *declares* it: nil for a plain
    /// `---`. Only a header cell tells the two apart — cmark writes no `align`
    /// for `---`, and the page's own stylesheet centres a `th` that has none
    /// (`text-align: -internal-center`) while a `td` starts at the left. So a
    /// renderer drawing the header reads this, and every other row `alignments`.
    public let declaredAlignments: [Alignment?]
    /// The column count the header declares. GFM truncates a longer data row
    /// and pads a shorter one, so this is the width of every row in the grid
    /// however many pipes were typed on any given line.
    public let columnCount: Int

    /// The number of rows the page draws — header plus data.
    public var rowCount: Int { rows.count }

    /// Parse a table block's source. Returns nil when the source is not a
    /// table: fewer than two lines, or a second line that is not a delimiter.
    public init?(source: String) {
        let lines = source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let header = Self.cells(lines[0])
        let delimiters = Self.cells(lines[1])
        // GFM: "The delimiter row must match the header row in the number of
        // cells. If not, a table will not be recognized." `| abc | def |` over
        // `| --- |` is three lines of paragraph, and the page renders it as
        // one — so an editor that draws a grid there is showing a document
        // nobody else has.
        guard !header.isEmpty, header.count == delimiters.count,
              delimiters.allSatisfy(Self.isDelimiterCell) else { return nil }

        let columns = header.count
        guard columns > 0 else { return nil }
        self.columnCount = columns
        let declared = (0..<columns).map {
            $0 < delimiters.count ? Self.declaredAlignment(delimiters[$0]) : nil
        }
        self.declaredAlignments = declared
        self.alignments = declared.map { $0 ?? .left }
        // Every row is exactly `columns` wide, because that is the table the
        // page lays out: `| bar |` under a two-column header renders an empty
        // second cell, and `| bar | baz | boo |` renders only the first two.
        func fit(_ row: [String]) -> [String] {
            row.count == columns ? row
                : row.count > columns ? Array(row.prefix(columns))
                : row + Array(repeating: "", count: columns - row.count)
        }
        self.rows = [fit(header)] + lines.dropFirst(2).map { fit(Self.cells($0)) }
    }

    /// The height the page gives this grid when it fits its pane: one line
    /// per cell. A table squeezed until its cells wrap is taller, and that
    /// height is `GFMTableGeometry.fitted`'s to give — it shrinks the columns
    /// and wraps the cells as the page does, which is about *fitting* rather
    /// than about the box model.
    public func height(_ m: GFMBoxMetrics) -> CGFloat { m.tableHeight(rows: rowCount) }

    // MARK: - Cells

    /// Split one table line into its cells, dropping the outer pipes.
    ///
    /// Only an *unescaped* pipe divides — one with no backslash directly
    /// before it, as cmark-gfm reads a row. `\|` is a literal one: it
    /// survives into the cell's text with that backslash removed, exactly as
    /// the page prints it.
    public static func cells(_ line: String) -> [String] {
        let units = Array(line.utf16)
        return scan(units, from: 0, count: units.count) { cell in
            String(utf16CodeUnits: cell, count: cell.count)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// How many cells one table line has, read straight off a line buffer.
    ///
    /// The block parser needs this to decide whether a delimiter row matches
    /// its header, and it works in UTF-16 units rather than `String`s. Sharing
    /// the scanner is the point: a parser that counts cells one way and a
    /// renderer that splits them another produce a grid with a column the
    /// document never had.
    public static func cellCount(_ b: [unichar], from: Int, count: Int) -> Int {
        scan(b, from: from, count: count) { _ in () }.count
    }

    /// One pass over a line's cells, handing each one's code units to `make`.
    private static func scan<T>(_ b: [unichar], from: Int, count: Int,
                                _ make: ([unichar]) -> T) -> [T] {
        var start = from, end = count
        while start < end, b[start] == 0x20 || b[start] == 0x09 { start += 1 }
        while end > start, b[end - 1] == 0x20 || b[end - 1] == 0x09 { end -= 1 }
        // A leading pipe opens the row rather than opening an empty first cell.
        if start < end, b[start] == 0x7C { start += 1 }

        var out: [T] = []
        var current: [unichar] = []
        var i = start
        while i < end {
            let c = b[i]
            if c == 0x5C, i + 1 < end, b[i + 1] == 0x7C {
                // **A backslash directly before a pipe escapes it, whatever
                // precedes it** — cmark-gfm's reading of a row, so the page's.
                // The cell holds the pipe without it. Read as escaped
                // backslashes, an even run made the pipe after it a divider:
                // `| a \\| b |` was two cells here and one on the page.
                current.append(0x7C)
                i += 2
                continue
            }
            if c == 0x7C {
                out.append(make(current))
                current = []
            } else {
                // Any other backslash stays, because the inline parser still
                // has to see `\*` — and `\\` — as an escape when it styles
                // the cell.
                current.append(c)
            }
            i += 1
        }
        // A trailing pipe closes the row; it does not open a last empty cell.
        // `| a |` is one cell, `| a ||` is two, the second of them empty.
        let trailingPipeClosed = current.allSatisfy { $0 == 0x20 || $0 == 0x09 }
        if !trailingPipeClosed || out.isEmpty { out.append(make(current)) }
        return out
    }

    /// `---`, `:--`, `--:` or `:-:`, and nothing else.
    private static func isDelimiterCell(_ cell: String) -> Bool {
        var body = Substring(cell)
        if body.hasPrefix(":") { body = body.dropFirst() }
        if body.hasSuffix(":") { body = body.dropLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    /// `:--` left, `:-:` centre, `--:` right; nil for `---`, which declares none.
    private static func declaredAlignment(_ cell: String) -> Alignment? {
        let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
        if left && right { return .center }
        return right ? .right : left ? .left : nil
    }
}

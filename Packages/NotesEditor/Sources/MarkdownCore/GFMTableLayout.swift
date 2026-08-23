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
        self.alignments = (0..<columns).map {
            $0 < delimiters.count ? Self.alignment(delimiters[$0]) : .left
        }
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

    /// The height the page gives this grid.
    ///
    /// One line per cell: the corpus's tables all fit their pane, and a cell
    /// whose text wraps is a taller row on the page than in the editor's
    /// image — which scales the whole bitmap down instead of wrapping. That
    /// divergence is about *fitting*, not about the box model, and it is the
    /// next thing to measure rather than something to fudge here.
    public func height(_ m: GFMBoxMetrics) -> CGFloat { m.tableHeight(rows: rowCount) }

    // MARK: - Cells

    /// Split one table line into its cells, dropping the outer pipes.
    ///
    /// Only an *unescaped* pipe divides. `\|` is a literal one — it survives
    /// into the cell's text with its backslash removed, exactly as the page
    /// prints it.
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
        var escaped = false
        var i = start
        while i < end {
            let c = b[i]
            if escaped {
                // A backslash escapes the pipe and nothing else here; anything
                // else keeps its backslash, because the inline parser still has
                // to see `\*` as an escape when it styles the cell.
                if c != 0x7C { current.append(0x5C) }
                current.append(c)
                escaped = false
            } else if c == 0x5C {
                escaped = true
            } else if c == 0x7C {
                out.append(make(current))
                current = []
            } else {
                current.append(c)
            }
            i += 1
        }
        if escaped { current.append(0x5C) }
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

    private static func alignment(_ cell: String) -> Alignment {
        let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
        if left && right { return .center }
        return right ? .right : .left
    }
}

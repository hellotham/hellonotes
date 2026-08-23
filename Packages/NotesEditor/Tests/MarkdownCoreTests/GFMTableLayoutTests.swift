//
//  GFMTableLayoutTests.swift
//  MarkdownCoreTests
//
//  The grid a pipe table describes. Every case here was a real disagreement
//  between the editor's picture of a table and the page's: a delimiter line
//  counted as a row, an escaped pipe counted as a column boundary, a delimiter
//  row that does not match its header accepted as a table at all.
//

import Foundation
import Testing
@testable import MarkdownCore

@Suite struct GFMTableLayoutTests {

    /// `| --- | --- |` sets the columns' alignment and draws nothing. Counted
    /// as a row it made every table one row taller than the page's — and since
    /// the editor was being measured by its *source lines* rather than by the
    /// picture it draws, three lines of pipes scored as two rendered rows and
    /// the error surfaced somewhere else entirely.
    @Test func theDelimiterLineIsARulerNotARow() {
        let t = GFMTableLayout(source: "| foo | bar |\n| --- | --- |\n| baz | bim |")
        #expect(t?.rowCount == 2)
        #expect(t?.rows[0] == ["foo", "bar"])
        #expect(t?.rows[1] == ["baz", "bim"])
        #expect(t?.columnCount == 2)
        // A header and a ruler and nothing else is still a table — of one row.
        #expect(GFMTableLayout(source: "| abc | def |\n| --- | --- |")?.rowCount == 1)
    }

    /// GFM: "The delimiter row must match the header row in the number of
    /// cells. If not, a table will not be recognized."
    @Test func aMismatchedDelimiterRowIsNotATable() {
        #expect(GFMTableLayout(source: "| abc | def |\n| --- |\n| bar |") == nil)
        // …nor is a second line that is not a delimiter at all.
        #expect(GFMTableLayout(source: "| abc | def |\n| bar | baz |") == nil)
        #expect(GFMTableLayout(source: "| abc | def |") == nil)
    }

    /// `| f\|oo |` is one cell holding `f|oo`. Split on every pipe it became
    /// two columns, and a table with a column it does not have is a different
    /// width, a different natural size and a different scale factor.
    @Test func anEscapedPipeIsTextNotABoundary() {
        let t = GFMTableLayout(source: "| f\\|oo  |\n| ------ |\n| b `\\|` az |")
        #expect(t?.columnCount == 1)
        #expect(t?.rows[0] == ["f|oo"])
        #expect(t?.rows[1] == ["b `|` az"])
        // A backslash before anything else stays: the inline styler still has
        // to see `\*` as an escape inside the cell.
        #expect(GFMTableLayout.cells("| a \\* b |") == ["a \\* b"])
    }

    /// The outer pipes bound the row; they do not open cells of their own.
    @Test func theOuterPipesOnlyBound() {
        #expect(GFMTableLayout.cells("| a | b |") == ["a", "b"])
        #expect(GFMTableLayout.cells("a | b") == ["a", "b"])
        #expect(GFMTableLayout.cells("| a |") == ["a"])
        // …but an *inner* pair does open an empty one.
        #expect(GFMTableLayout.cells("| a || b |") == ["a", "", "b"])
    }

    /// The header declares the column count; the page pads a short row and
    /// truncates a long one, and the grid is rectangular either way.
    @Test func everyRowIsTheHeadersWidth() {
        let t = GFMTableLayout(source: "| abc | def |\n| --- | --- |\n| bar |\n| bar | baz | boo |")
        #expect(t?.rowCount == 3)
        #expect(t?.rows[1] == ["bar", ""])
        #expect(t?.rows[2] == ["bar", "baz"])
    }

    @Test func alignmentComesFromTheDelimitersColons() {
        let t = GFMTableLayout(source: "| a | b | c | d |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |")
        #expect(t?.alignments == [.left, .center, .right, .left])
        // The delimiter row need not carry outer pipes either.
        let bare = GFMTableLayout(source: "| abc | defghi |\n:-: | -----------:\nbar | baz")
        #expect(bare?.alignments == [.center, .right])
        #expect(bare?.rowCount == 2)
    }

    /// The block parser counts cells off a UTF-16 line buffer and the renderer
    /// splits them out of a `String`. One scanner, so the count that decides
    /// whether this *is* a table cannot disagree with the split that decides
    /// what is in it.
    @Test func theCountAndTheSplitAreTheSameWalk() {
        for line in ["| a | b |", "a | b", "| f\\|oo |", "| a || b |", "|x|", "  | a | b |  ",
                     ":-: | -----------:", "| --- |"] {
            let units = Array(line.utf16)
            #expect(GFMTableLayout.cellCount(units, from: 0, count: units.count)
                    == GFMTableLayout.cells(line).count, "\(line)")
        }
    }

    /// The height the page gives the grid, straight out of the shared box
    /// model — one place, so the editor's band and the `<table>` cannot drift.
    @Test func theHeightIsTheBoxModels() {
        let m = GFMBoxMetrics(base: 16)
        let t = GFMTableLayout(source: "| foo | bar |\n| --- | --- |\n| baz | bim |")
        #expect(t?.height(m) == m.tableHeight(rows: 2))
        #expect(t?.height(m) == 75)
    }
}

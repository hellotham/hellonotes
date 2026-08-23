//
//  GFMTableGeometryTests.swift
//  MarkdownEditorTests
//
//  The size of the picture the editor draws in place of a table's source.
//
//  This is the number the parity sweep leans on: the app draws the grid, this
//  package says how big it is, and the two agreeing is what lets a tool that
//  cannot link the app still measure a table against the Preview's `<table>`.
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore

@MainActor
@Suite struct GFMTableGeometryTests {

    /// The height is the box model's, to the point — three rows of source are
    /// two rows of table, and the collapsed borders are boxes of their own.
    /// WebKit lays this very table out in 75pt.
    @Test func theHeightIsTheBoxModelsAndNotTheSourcesLineCount() {
        let theme = EditorTheme(fontSize: 16)
        let grid = try? #require(GFMTableGeometry.grid(
            source: "| foo | bar |\n| --- | --- |\n| baz | bim |", theme: theme))
        #expect(grid?.rowCount == 2)
        #expect(grid?.naturalSize.height == 75)
        #expect(grid?.naturalSize.height == theme.metrics.tableHeight(rows: 2))
        // …and one more line of source is one more row, not one more line.
        let taller = GFMTableGeometry.grid(
            source: "| foo | bar |\n| --- | --- |\n| baz | bim |\n| a | b |", theme: theme)
        #expect(taller?.naturalSize.height == 112)
    }

    /// Not a table, no picture — the source stays on screen, which is the right
    /// fallback and the same one the page reaches for.
    @Test func aMismatchedDelimiterRowMeasuresNothing() {
        let theme = EditorTheme(fontSize: 16)
        #expect(GFMTableGeometry.grid(source: "| abc | def |\n| --- |\n| bar |", theme: theme) == nil)
        #expect(GFMTableGeometry.fittedSize(source: "not a table", theme: theme, maxWidth: 600) == nil)
    }

    /// The header is set semibold (`th { font-weight: 600 }`), so it is
    /// measured semibold. Measured in the body font, the grid line ran through
    /// the last letter of the widest heading.
    @Test func theHeaderIsMeasuredInItsOwnWeight() {
        let theme = EditorTheme(fontSize: 16)
        let grid = try? #require(GFMTableGeometry.grid(
            source: "| wwwwwwwwww |\n| --- |\n| x |", theme: theme))
        #expect(grid?.headerFont != grid?.bodyFont)
        let header = NSAttributedString(string: "wwwwwwwwww",
                                        attributes: [.font: theme.bodyBold]).size().width
        #expect(grid?.columnTextWidths.first == header.rounded(.up))
    }

    /// A table that fits keeps its natural size — stretched to the pane it
    /// would be a grid the Preview never draws.
    @Test func aTableThatFitsKeepsItsNaturalSize() {
        let theme = EditorTheme(fontSize: 16)
        let source = "| a | b |\n| --- | --- |\n| c | d |"
        let natural = GFMTableGeometry.grid(source: source, theme: theme)
        let fitted = GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: 900)
        #expect(fitted?.naturalSize == natural?.naturalSize)
        #expect(fitted?.rowHeights.allSatisfy { $0 == theme.metrics.tableRowHeight } == true)
        // A degenerate pane must not divide by nothing.
        #expect(GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: 0)?.naturalSize
                == natural?.naturalSize)
    }

    /// A table too wide for its pane does **not** scale. A browser shrinks the
    /// columns and the cell text wraps, so the table gets *taller*; scaling the
    /// bitmap made it *shorter*, and the two moved in opposite directions — 27pt
    /// on a four-column table at a 420pt pane, 84pt on a wider one. Nothing in
    /// the spec corpus is wide enough to notice, which is why 672 examples
    /// agreed while a README did not.
    @Test func anOverWideTableShrinksItsColumnsAndGrowsTaller() {
        let theme = EditorTheme(fontSize: 16)
        let source = "| Quarter | Accounts | Churn | Support cost |\n"
            + "| --- | ---: | ---: | ---: |\n"
            + "| Q1 | 1,204 | 3.1% | $4.10 |"
        let natural = GFMTableGeometry.grid(source: source, theme: theme)!
        let pane = natural.naturalSize.width - 40
        let fitted = GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: pane)!
        // Narrower and taller — the two halves of "it wrapped instead of
        // scaling". Not `<= pane`: three of these four headers are single words
        // that cannot break, so the table's floor is above the pane and it
        // overflows the last few points, exactly as the page does. That case is
        // pinned on its own below.
        #expect(fitted.naturalSize.width < natural.naturalSize.width)
        #expect(fitted.naturalSize.height > natural.naturalSize.height)
        #expect(fitted.rowHeights.contains { $0 > theme.metrics.tableRowHeight })
        // Narrower columns, but never narrower than the longest word in them: a
        // column that cannot break is a column that overflows, which is what a
        // browser does too.
        for (c, width) in fitted.columnTextWidths.enumerated() {
            #expect(width <= natural.columnTextWidths[c] + 0.5, "column \(c) grew")
        }
        let longest = NSAttributedString(string: "Support",
                                         attributes: [.font: theme.bodyBold]).size().width
        #expect(fitted.columnTextWidths.last! >= longest - 0.5)
    }

    /// Squeezed past the point where even the longest word in every column
    /// fits, the table overflows rather than clipping or hyphenating — which is
    /// what a browser does with it too. Worth pinning, because the tempting
    /// alternative (shrink anyway) silently cuts the text off.
    @Test func aTableSqueezedPastItsMinimumsOverflows() {
        let theme = EditorTheme(fontSize: 16)
        let source = "| Quarter | Accounts | Churn | Support cost |\n"
            + "| --- | ---: | ---: | ---: |\n"
            + "| Q1 | 1,204 | 3.1% | $4.10 |"
        let fitted = GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: 120)!
        #expect(fitted.naturalSize.width > 120)
        let longest = NSAttributedString(string: "Accounts",
                                         attributes: [.font: theme.bodyBold]).size().width
        #expect(fitted.columnTextWidths[1] >= longest - 0.5)
    }

    /// A cell breaks where the page breaks it. UAX #14 makes a hyphen and a
    /// solidus break opportunities and WebKit takes them, so `--watch` in a
    /// narrow cell is two lines there. Counting a cell as breakable only at
    /// spaces made its column demand width the page never gives it, and the
    /// row came out a line short — invisible at any width where the table fits.
    @Test func aCellBreaksAfterAHyphenOrSolidusAsThePageDoes() {
        let font = EditorTheme(fontSize: 16).body
        func width(_ s: String) -> CGFloat {
            NSAttributedString(string: s, attributes: [.font: font]).size().width
        }
        // Wide enough for "--" and not for "--watch": the page gets two lines.
        let narrow = width("--watch") - 4
        #expect(GFMTableGeometry.wrappedLineCount("--watch", font: font, width: narrow) == 2)
        #expect(GFMTableGeometry.wrappedLineCount("a/b/c", font: font,
                                                  width: width("a/b/c") - 4) == 2)
        // A run with no opportunity in it stays one line however narrow.
        #expect(GFMTableGeometry.wrappedLineCount("watch", font: font, width: 4) == 1)
    }

    /// The wrap count is what turns a squeezed column into a taller row.
    @Test func aCellWrapsOnlyWhenItDoesNotFit() {
        let font = EditorTheme(fontSize: 16).body
        let text = "Support cost per account"
        let full = NSAttributedString(string: text, attributes: [.font: font]).size().width
        #expect(GFMTableGeometry.wrappedLineCount(text, font: font, width: full + 10) == 1)
        #expect(GFMTableGeometry.wrappedLineCount(text, font: font, width: full / 2) > 1)
        // A single word that cannot fit still occupies one line rather than none.
        #expect(GFMTableGeometry.wrappedLineCount("indivisible", font: font, width: 1) == 1)
    }

    /// Everything scales with the root font, because everything under it does:
    /// a table that kept 16pt-base padding while the type grew would be the one
    /// block on the page that got tighter as the text got bigger.
    @Test func theGridScalesWithTextSize() {
        for base in [12, 16, 20, 28] as [CGFloat] {
            let theme = EditorTheme(fontSize: base)
            let grid = GFMTableGeometry.grid(
                source: "| foo | bar |\n| --- | --- |\n| baz | bim |", theme: theme)
            #expect(grid?.rowHeight == theme.metrics.tableRowHeight, "row at \(base)")
            #expect(grid?.naturalSize.height == theme.metrics.tableHeight(rows: 2), "height at \(base)")
        }
    }
}

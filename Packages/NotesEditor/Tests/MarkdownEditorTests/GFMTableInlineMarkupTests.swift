//
//  GFMTableInlineMarkupTests.swift
//  MarkdownEditorTests
//
//  A table's cells are Markdown, and the editor's picture of a table has to be
//  measured from each cell as the page renders it — not as it was typed.
//  `| Ask Library (**⇧⌘J**) |` is "Ask Library (⇧⌘J)" on the page, with the keys
//  semibold; the grid measured (and drew) the asterisks, in the body font. So a
//  column holding a link was as wide as the link's destination, and a squeezed
//  one wrapped at words the page never shows (docs/implemented.md §51.27; seen
//  on the HN-iPad simulator in DefaultCollection's Intelligence.md).
//
//  The control throughout: a table of plain text measures exactly as it did.
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct GFMTableInlineMarkupTests {

    private let theme = EditorTheme(fontSize: 16)

    /// A one-column table: `header` over `cell`.
    private func table(_ header: String, _ cell: String) -> String {
        "| \(header) |\n| --- |\n| \(cell) |"
    }

    private func width(_ text: String, _ font: PlatformFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    // MARK: - Measured as the page shows it

    /// A link, a wiki link (with and without an alias), strikethrough and an
    /// escaped `*` all render in the body font, so each is measured exactly as
    /// the plain text it renders as — at its natural size, and squeezed into a
    /// pane where it wraps. A link's destination is not a word on the page, and
    /// neither is the path in front of an alias.
    @Test func aMarkedUpCellMeasuresAsTheTextThePageShows() throws {
        let pairs: [(markup: String, shown: String)] = [
            ("[the link text](https://example.com/a/rather/long/path/to/somewhere)", "the link text"),
            ("[[Wiki Link]]", "Wiki Link"),
            // In a table the alias's pipe is escaped, or it divides the cell.
            ("[[Examples/Nested Note\\|shown instead]]", "shown instead"),
            ("~~struck out~~", "struck out"),
            ("a \\* b", "a * b"),
        ]
        for (markup, shown) in pairs {
            for pane in [CGFloat(900), 90] {
                let marked = try #require(GFMTableGeometry.fitted(
                    source: table("h", markup), theme: theme, maxWidth: pane))
                let plain = try #require(GFMTableGeometry.fitted(
                    source: table("h", shown), theme: theme, maxWidth: pane))
                #expect(marked.columnTextWidths == plain.columnTextWidths,
                        "\(markup) at \(pane)pt: \(marked.columnTextWidths) against \(plain.columnTextWidths)")
                #expect(marked.rowHeights == plain.rowHeights,
                        "\(markup) at \(pane)pt: \(marked.rowHeights) against \(plain.rowHeights)")
                #expect(marked.naturalSize == plain.naturalSize, "\(markup) at \(pane)pt")
            }
        }
    }

    /// Bold, emphasis and code are set in their own faces, as the page sets
    /// them — `strong` at 600, `em` italic, `code` monospaced at 85% inside
    /// `.4em` of padding a side — and the column is as wide as that text.
    @Test func boldEmphasisAndCodeAreMeasuredInTheirOwnFaces() throws {
        func column(_ cell: String) throws -> CGFloat {
            try #require(GFMTableGeometry.grid(source: table("h", cell), theme: theme)).columnTextWidths[0]
        }
        #expect(try column("**bold words**") == width("bold words", theme.bodyBold).rounded(.up))
        #expect(try column("*emphasised words*") == width("emphasised words", theme.bodyItalic).rounded(.up))
        // Code was already measured this way, and must go on being.
        #expect(try column("`code`")
                == (width("code", theme.mono) + 2 * theme.metrics.inlineCodePadX).rounded(.up))
        // An escaped pipe is one pipe in one cell — also already so.
        #expect(try column("a \\| b") == width("a | b", theme.body).rounded(.up))
    }

    /// The symptom's own row, from the tour note: the column is as wide as
    /// "Ask Library (⇧⌘J)" with the keys in semibold, not as the asterisks.
    @Test func theTourNotesRowMeasuresWithoutItsAsterisks() throws {
        let source = "| Action | Result |\n| --- | --- |\n"
            + "| Ask Library (**⇧⌘J**) | answers from your notes, with citations |"
        let grid = try #require(GFMTableGeometry.grid(source: source, theme: theme))
        let shown = NSMutableAttributedString(string: "Ask Library (", attributes: [.font: theme.body])
        shown.append(NSAttributedString(string: "⇧⌘J", attributes: [.font: theme.bodyBold]))
        shown.append(NSAttributedString(string: ")", attributes: [.font: theme.body]))
        #expect(grid.columnTextWidths[0]
                == max(width("Action", theme.bodyBold), shown.size().width).rounded(.up))
    }

    // MARK: - What is drawn

    /// The text a cell is drawn from is its rendered text — no markers, in the
    /// page's faces — and it is the text its column was measured from.
    @Test func aCellIsDrawnAsItsRenderedText() throws {
        let source = "| **bold** | *em* | `code` | ~~strike~~ | [link](https://example.com/x) | [[Target\\|alias]] | a \\| b |\n"
            + "| --- | --- | --- | --- | --- | --- | --- |\n"
            + "| **bold** | *em* | `code` | ~~strike~~ | [link](https://example.com/x) | [[Wiki Link]] | \\*x\\* |"
        let grid = try #require(GFMTableGeometry.grid(source: source, theme: theme))
        #expect(grid.cells[0].map(Self.drawn) == ["bold", "em", "code", "strike", "link", "alias", "a | b"])
        #expect(grid.cells[1].map(Self.drawn) == ["bold", "em", "code", "strike", "link", "Wiki Link", "*x*"])
        let body = grid.cells[1]
        // Each in its face, with the table's tabular figures.
        let tabular = GFMTableGeometry.tabularFigures
        #expect(Self.attribute(.font, of: "bold", in: body[0]) as? PlatformFont == tabular(theme.bodyBold))
        #expect(Self.attribute(.font, of: "em", in: body[1]) as? PlatformFont == tabular(theme.bodyItalic))
        #expect(Self.attribute(.font, of: "em", in: grid.cells[0][1]) as? PlatformFont
                    == tabular(theme.bodyBoldItalic), "`th em` is semibold italic")
        let code = try #require(Self.attribute(.font, of: "code", in: body[2]) as? PlatformFont)
        let mono = PlatformFont.monospacedSystemFont(ofSize: theme.metrics.codeSize, weight: .regular)
        #expect(code.fontName == mono.fontName && code.pointSize == mono.pointSize)
        #expect(Self.attribute(inlineCodeAttribute, of: "code", in: body[2]) != nil, "no pill for the code")
        #expect(Self.attribute(.strikethroughStyle, of: "strike", in: body[3]) != nil)
        #expect(Self.attribute(.foregroundColor, of: "link", in: body[4]) as? PlatformColor == theme.accent)
        #expect(Self.attribute(.link, of: "link", in: body[4]) == nil, "a picture is not a link")
        for c in 0..<grid.columnCount {
            #expect(grid.columnTextWidths[c] == grid.cells.map { $0[c].size().width.rounded(.up) }.max(),
                    "column \(c) is not as wide as what is drawn in it")
        }
    }

    /// The control: a plain cell is its text in its row's font — with the
    /// table's tabular figures — and nothing else.
    @Test func aPlainCellIsItsTextInItsRowsFont() throws {
        let grid = try #require(GFMTableGeometry.grid(
            source: "| Plain head |\n| --- |\n| plain words |", theme: theme))
        #expect(grid.cells[0][0].string == "Plain head" && grid.cells[1][0].string == "plain words")
        #expect(Self.attribute(.font, of: "Plain", in: grid.cells[0][0]) as? PlatformFont
                    == GFMTableGeometry.tabularFigures(theme.bodyBold))
        #expect(Self.attribute(.font, of: "plain", in: grid.cells[1][0]) as? PlatformFont
                    == GFMTableGeometry.tabularFigures(theme.body))
    }

    /// Squeezed, the lines drawn are the lines counted: a cell holds as many
    /// lines as its row is tall, and they cover its text in order.
    @Test func theLinesDrawnAreTheLinesCounted() throws {
        let source = "| h |\n| --- |\n"
            + "| **Ask** the [library](https://example.com/q) about `summary:` and ~~more~~ |"
        let grid = try #require(GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: 110))
        let lines = grid.cellLines[1][0]
        #expect(lines.count > 1, "the cell should wrap in a 110pt pane")
        #expect(grid.rowHeights[1]
                == CGFloat(lines.count) * theme.metrics.bodyLineHeight + 2 * theme.metrics.cellPadY)
        var next = 0
        for line in lines {
            #expect(line.location == next)
            next = NSMaxRange(line)
        }
        #expect(next == grid.cells[1][0].length)
    }

    /// The picture is the size the geometry reserved for it — drawn here in the
    /// package, where the parity harness draws it too.
    @Test func thePictureIsTheSizeTheGeometryReserved() throws {
        let source = "| **Action** | `code` |\n| --- | :-: |\n| [a link](https://example.com) | ~~no~~ |"
        for pane in [CGFloat(900), 120] {
            let grid = try #require(GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: pane))
            let image = try #require(GFMTableImage.image(source: source, maxWidth: pane,
                                                         theme: theme, isDark: false))
            #expect(image.size == grid.naturalSize, "at \(pane)pt")
        }
        #expect(GFMTableImage.image(source: "not a table", maxWidth: 600, theme: theme, isDark: false) == nil)
    }

    // MARK: - What the page does that the source does not spell out

    /// `<br>` is how a cell breaks a line — a row is one line of source, so
    /// nothing else can — and the page breaks it there. The picture drew the
    /// tag: `first line<br>second` as one line holding the four characters,
    /// measured as such, where the page has two lines and a row a line taller.
    @Test func aBreakTagBreaksTheCellsLine() throws {
        let m = theme.metrics
        for tag in ["<br>", "<br/>", "<br />", "<BR>"] {
            let grid = try #require(GFMTableGeometry.grid(source: table("h", "first line\(tag)second"),
                                                          theme: theme))
            #expect(grid.cellLines[1][0].count == 2, "\(tag)")
            #expect(grid.rowHeights[1] == 2 * m.bodyLineHeight + 2 * m.cellPadY, "\(tag)")
            #expect(grid.naturalSize.height == grid.rowHeights.reduce(0, +) + 3 * m.hairline, "\(tag)")
            #expect(grid.columnTextWidths[0] == width("first line", theme.body).rounded(.up),
                    "\(tag): as wide as its longer line, not as both lines end to end")
            #expect(!Self.drawn(grid.cells[1][0]).contains("<"), "\(tag) is drawn as its source")
        }
        // A break that ends the cell starts no line after it, as on the page;
        // one that opens it leaves an empty line above; two make an empty one
        // between.
        func lineCount(_ cell: String) throws -> Int {
            try #require(GFMTableGeometry.grid(source: table("h", cell), theme: theme)).cellLines[1][0].count
        }
        #expect(try lineCount("only<br>") == 1)
        #expect(try lineCount("<br>after") == 2)
        #expect(try lineCount("a<br><br>b") == 3)
    }

    /// Squeezed, a broken cell wraps each of its lines on its own, and no line
    /// runs across a break.
    @Test func aBrokenCellWrapsEachLineOnItsOwn() throws {
        let source = table("h", "several words on the first line<br>then the second")
        let grid = try #require(GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: 140))
        let text = grid.cells[1][0]
        let string = text.string as NSString
        let breakAt = string.range(of: "\u{2028}").location
        try #require(breakAt != NSNotFound, "the <br> made no break")
        let lines = grid.cellLines[1][0]
        #expect(lines.count > 2, "both halves should wrap at 140pt")
        #expect(lines.allSatisfy { NSMaxRange($0) <= breakAt + 1 || $0.location > breakAt },
                "a line crosses the break")
        #expect(grid.rowHeights[1] == CGFloat(lines.count) * theme.metrics.bodyLineHeight
                    + 2 * theme.metrics.cellPadY)
    }

    /// Any other tag is markup the page does not draw. `H<sub>2</sub>O` is
    /// "H2O" there — smaller and lower, a style the picture does not attempt —
    /// and the picture drew eleven characters of source.
    @Test func otherInlineTagsAreNotDrawn() throws {
        let grid = try #require(GFMTableGeometry.grid(
            source: table("h", "H<sub>2</sub>O and <kbd>K</kbd><!-- a note -->"), theme: theme))
        #expect(Self.drawn(grid.cells[1][0]) == "H2O and K")
    }

    /// `table { font-variant: tabular-nums }`, from GitHub's stylesheet: every
    /// figure in a table is as wide as every other, so a column of numbers
    /// lines up. The picture measured SF's proportional figures — `1111` at
    /// 28.4pt against `0000` at 39.1 — so a column of figures was narrower in
    /// Edit than on the page.
    @Test func figuresInATableAreTabular() throws {
        let ones = try #require(GFMTableGeometry.grid(source: table("h", "1111"), theme: theme))
        let zeros = try #require(GFMTableGeometry.grid(source: table("h", "0000"), theme: theme))
        #expect(ones.columnTextWidths == zeros.columnTextWidths)
        let header = try #require(GFMTableGeometry.grid(source: table("1111", "h"), theme: theme))
        let zeroHeader = try #require(GFMTableGeometry.grid(source: table("0000", "h"), theme: theme))
        #expect(header.columnTextWidths == zeroHeader.columnTextWidths, "the header row too")
        // Only figures: a letter keeps its own width.
        let letters = try #require(GFMTableGeometry.grid(source: table("h", "iiii"), theme: theme))
        #expect(letters.columnTextWidths[0] == width("iiii", theme.body).rounded(.up))
    }

    /// A cell's baseline is where the page puts it: the cell's top border and
    /// padding, half the line's leading, then the ascent — the leading taken
    /// from the font's ascent and descent each rounded to a whole point, which
    /// is what both engines lay a line out on (`BlockBoxes.halfLeading`).
    ///
    /// The picture centred each line on `size().height` instead, which rounds
    /// the font's extent *up* — 19 for the system font at 16pt, against the 18
    /// both engines use — so every cell's text sat half a point high: measured
    /// at 2× against the page, 11.5pt below the border where Preview has 12.
    /// Drawn at 4× here, where half a point is two pixel rows, on both
    /// platforms, because each platform's string drawing decides for itself
    /// where under the origin a baseline goes.
    @Test func aCellsBaselineIsWhereThePageDrawsIt() throws {
        let grid = try #require(GFMTableGeometry.grid(source: table("Header", "Hxlm cell"), theme: theme))
        let scale: CGFloat = 4
        let w = Int(grid.naturalSize.width * scale), h = Int(grid.naturalSize.height * scale)
        let context = try #require(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // y-down, as the picture is drawn.
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: scale, y: -scale)
        // In the light appearance, pinned — as `PlatformDraw.image` pins it —
        // or the text is drawn light whenever the Mac has turned dark.
        #if canImport(AppKit)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            GFMTableImage.draw(grid, theme: theme, isDark: false, in: context)
            NSGraphicsContext.current = previous
        }
        #else
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            UIGraphicsPushContext(context)
            GFMTableImage.draw(grid, theme: theme, isDark: false, in: context)
            UIGraphicsPopContext()
        }
        #endif
        let data = try #require(context.data)
        /// The lowest row of dark ink between two rows of the picture — the
        /// baseline, for text with no descenders. Memory row 0 is the top row.
        func lastInkRow(from top: Int, to bottom: Int) -> Int? {
            var last: Int?
            for y in top..<bottom {
                for x in 0..<w {
                    let p = data.advanced(by: y * context.bytesPerRow + x * 4)
                    let r = Int(p.load(as: UInt8.self)), g = Int(p.load(fromByteOffset: 1, as: UInt8.self)),
                        b = Int(p.load(fromByteOffset: 2, as: UInt8.self))
                    if (r + g + b) / 3 < 100 { last = y; break }
                }
            }
            return last
        }
        let m = theme.metrics
        for (r, font) in [(0, theme.bodyBold), (1, theme.body)] {
            let rowTop = m.hairline + CGFloat(r) * (m.tableRowHeight + m.hairline)
            let content = font.ascender.rounded() + (-font.descender).rounded()
            let expected = rowTop + m.cellPadY + (m.bodyLineHeight - content) / 2 + font.ascender.rounded()
            let ink = try #require(lastInkRow(from: Int(rowTop * scale),
                                              to: Int((rowTop + m.tableRowHeight) * scale)))
            let baseline = CGFloat(ink + 1) / scale
            #expect(abs(baseline - expected) <= 0.25, "row \(r): baseline at \(baseline), the page's at \(expected)")
        }
    }

    /// What is drawn: every character but the carrier of a code span's
    /// leading padding, which is a space too small to see.
    private static func drawn(_ text: NSAttributedString) -> String {
        let ns = text.string as NSString
        return (0..<ns.length).compactMap { i in
            text.attribute(GFMTableGeometry.codePaddingAttribute, at: i, effectiveRange: nil) == nil
                ? ns.substring(with: NSRange(location: i, length: 1)) : nil
        }.joined()
    }

    /// `key` on the first character of `word` in `text`.
    private static func attribute(_ key: NSAttributedString.Key, of word: String,
                                  in text: NSAttributedString) -> Any? {
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(key, at: range.location, effectiveRange: nil)
    }

    // MARK: - The control

    /// A table of plain text is measured exactly as it was at its natural size:
    /// every cell in its row's font and nothing else.
    @Test func aPlainTableMeasuresExactlyAsBefore() throws {
        let source = "| Quarter | Accounts | Churn | Support cost |\n"
            + "| --- | ---: | ---: | ---: |\n"
            + "| Q1 | 1,204 | 3.1% | $4.10 |"
        let grid = try #require(GFMTableGeometry.grid(source: source, theme: theme))
        for c in 0..<grid.columnCount {
            // In the row's font with the table's tabular figures.
            let widest = grid.rows.enumerated()
                .map { r, row in
                    width(row[c], GFMTableGeometry.tabularFigures(r == 0 ? theme.bodyBold : theme.body))
                }
                .max() ?? 0
            #expect(grid.columnTextWidths[c] == widest.rounded(.up), "column \(c)")
        }
    }

    // MARK: - Squeezed, as WebKit squeezes it

    /// Found by the document gate once a table of long cells was in it, and
    /// true of plain text as much as of Markdown: two rules the fitted layout
    /// had of its own. First, a line's trailing space hangs, as CSS hangs it —
    /// it counts neither towards whether the line fits nor towards the
    /// narrowest its column can be. Counted, a line that fitted to the letter
    /// broke a word early: "Support cost per account" in exactly the width of
    /// "Support cost" came out as three lines, not the page's two.
    @Test func aLinesTrailingSpaceHangs() {
        let text = NSAttributedString(string: "Support cost per account", attributes: [.font: theme.body])
        let lines = GFMTableGeometry.lineRanges(text, width: width("Support cost", theme.body))
        #expect(lines.map { (text.string as NSString).substring(with: $0) } == ["Support cost ", "per account"])
        #expect(GFMTableGeometry.wrappedLineCount(text, width: width("Support cost", theme.body)) == 2)
    }

    /// Second, an over-wide table shares its width as WebKit shares the page's
    /// (`AutoTableLayout`): every column starts at its minimum — its longest
    /// word — and the whole width is then shared in proportion to each column's
    /// maximum — its longest cell — none going below its minimum, as boxes with
    /// their padding and border. The rule it replaced shared only the space
    /// above the minimums, in proportion to how much each could give: a table
    /// of long cells got a wider first column than the page's, and two of its
    /// rows wrapped in Preview and not in Edit — 48pt at 560pt.
    @Test func aSqueezedTableSharesItsWidthAsWebKitDoes() throws {
        let source = "| Action | Result | Notes |\n| --- | --- | --- |\n"
            + "| Summarise Note | writes summary: into front matter | never the body |\n"
            + "| Suggest Tags | adds to tags: | see Organising |\n"
            + "| Rewrite or Expand | proposes a change you accept or reject | overwrites never overwrites |"
        let natural = try #require(GFMTableGeometry.grid(source: source, theme: theme))
        let m = theme.metrics
        let chrome = 2 * m.cellPadX + m.hairline
        let maxes = natural.columnTextWidths.map { $0 + chrome }
        let mins = (0..<natural.columnCount).map { c in
            natural.rows.enumerated().flatMap { r, row in
                row[c].split(separator: " ").map { width(String($0), r == 0 ? theme.bodyBold : theme.body) }
            }.map { $0.rounded(.up) }.max()! + chrome
        }
        for pane in [CGFloat(520), 420] {
            let fitted = try #require(GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: pane))
            var expected = mins
            var available = pane - m.hairline
            var wanted = maxes.reduce(0, +)
            for c in expected.indices {
                expected[c] = max(mins[c], available * maxes[c] / wanted)
                available -= expected[c]
                wanted -= maxes[c]
            }
            #expect(available >= -0.01, "the rule overshot at \(pane)pt — this table should not need the take-back")
            for c in expected.indices {
                #expect(abs(fitted.columnTextWidths[c] + chrome - expected[c]) < 0.01,
                        "column \(c) at \(pane)pt: \(fitted.columnTextWidths[c] + chrome), expected \(expected[c])")
            }
        }
    }
}

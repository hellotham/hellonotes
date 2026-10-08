//
//  GFMTableImage.swift
//  MarkdownEditor
//
//  The picture the editor draws in place of a table's source: the grid
//  `GFMTableGeometry` measured, drawn — and nothing that grid does not say.
//
//  It was the app's (`TableImageRenderer`), on the grounds that pixels are the
//  app's business and the package only had to know how big a table is. That
//  held while a cell was a string. Once a cell is styled text — bold in its own
//  face, code in a pill, a link as its label — the text a cell is measured from
//  and the text it is drawn from have to be one value, and the parity harness,
//  which cannot link the app, has to be able to *look* at the result: it drew a
//  blank box the size of the table beside Preview's `<table>`, which is also
//  what a failed render looks like.
//
//  GitHub's palette, from `GFMPalette` — the numbers the Preview's stylesheet
//  is built from: text `--fgColor-default`, grid `--borderColor-default`, and
//  `--bgColor-muted` striping `tr:nth-child(2n)`. There is no header band: the
//  header is semibold and sits on the default row like every odd row.
//
//  Two things the app's renderer once decided for itself, and got wrong both
//  times, and which live in the geometry now:
//
//  * The grid lines were stroked *inside* the row heights, so a table came out
//    one hairline per row shorter than the page's `border-collapse: collapse`
//    — 3pt on the commonest table there is, and growing with every row.
//  * `components(separatedBy: "|")` split on escaped pipes too, so `| f\|oo |`
//    became two columns instead of one and the whole grid was a different width.
//

import CoreGraphics
import Foundation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

public enum GFMTableImage {

    /// The table in `source` drawn for `isDark` at the size the editor reserves
    /// for it inside `maxWidth`, or nil when `source` is not a table.
    ///
    /// Fitted, not natural: a table too wide for the pane shrinks its columns
    /// and wraps its cells the way a browser does (`GFMTableGeometry.fitted`),
    /// and the picture is drawn at exactly that size — never drawn wide and
    /// scaled down, which made an over-wide table *shorter* where the page makes
    /// it taller.
    public static func image(source: String, maxWidth: CGFloat, theme: EditorTheme,
                             isDark: Bool) -> PlatformImage? {
        guard let grid = GFMTableGeometry.fitted(source: source, theme: theme, maxWidth: maxWidth)
        else { return nil }
        return PlatformDraw.image(size: grid.naturalSize, isDark: isDark) { context in
            draw(grid, theme: theme, isDark: isDark, in: context)
        }
    }

    /// `grid`, with its top-left corner at the origin of a y-down `context`.
    static func draw(_ grid: GFMTableGrid, theme: EditorTheme, isDark: Bool, in context: CGContext) {
        let m = theme.metrics
        let palette = GFMPalette.of(isDark: isDark)
        let padX = m.cellPadX, border = m.hairline, lineHeight = m.bodyLineHeight
        let total = grid.naturalSize
        // Column and row *box* extents, borders included. A collapsed border is
        // a box of its own — the cells sit between them, which is why the sums
        // below start at one border and step by one after every track.
        let columnBoxes = grid.columnTextWidths.map { $0 + 2 * padX }
        /// The top of row `r`, over rows that are not all one height.
        func top(_ r: Int) -> CGFloat {
            border + grid.rowHeights[..<r].reduce(0) { $0 + $1 + border }
        }

        // Zebra striping: GitHub fills `tr:nth-child(2n)`. Counting the header
        // as child 1, the striped rows are the odd row indices; the others are
        // left transparent, so the grid sits on the editor's own canvas.
        context.setFillColor(PlatformColor.gfm(palette.codeBackground).cgColor)
        for r in 0..<grid.rowCount where r % 2 == 1 {
            context.fill(CGRect(x: 0, y: top(r), width: total.width, height: grid.rowHeights[r]))
        }

        for r in 0..<grid.rowCount {
            let font = grid.font(row: r)
            // Every line sits in a line box of the row's own font, centred in
            // `bodyLineHeight` as CSS centres a line's glyphs. The strut puts
            // that font on every line — a line of nothing but code is otherwise
            // set in code's smaller face, and its baseline rises above its
            // neighbours'.
            let strut = Self.strut(font)
            // Centred on the font's ascent and descent each rounded to a whole
            // point — what both engines lay a line out on, and the rule the
            // editor's own text follows (`BlockBoxes.halfLeading`) — with the
            // baseline that rounded ascent below where string drawing starts.
            // It was centred on `size().height`, which rounds the extent *up*:
            // 19 for the system font at 16pt against the engines' 18, so every
            // cell's text sat half a point high of the page's.
            let content = font.ascender.rounded() + (-font.descender).rounded()
            let halfLeading = max(0, (lineHeight - content) / 2)
            var x = border
            for c in 0..<min(grid.columnCount, columnBoxes.count) {
                let box = columnBoxes[c]
                let text = grid.cells[r][c]
                let lines = grid.cellLines[r][c]
                // `vertical-align: middle`, a table cell's own default: a cell
                // with fewer lines than its row's tallest sits in the middle.
                let blockTop = top(r) + (grid.rowHeights[r] - CGFloat(lines.count) * lineHeight) / 2
                let string = text.string as NSString
                for (i, range) in lines.enumerated() {
                    let shown = GFMTableGeometry.hangingSpaceTrimmed(range, in: string)
                    guard shown.length > 0 else { continue }
                    let line = text.attributedSubstring(from: shown)
                    let width = line.size().width
                    let left: CGFloat
                    switch alignment(of: c, row: r, in: grid) {
                    case .left:   left = x + padX
                    case .right:  left = x + box - padX - width
                    case .center: left = x + (box - width) / 2
                    }
                    let lineTop = blockTop + CGFloat(i) * lineHeight
                    drawCodePills(in: line, left: left, lineTop: lineTop, theme: theme,
                                  palette: palette, context: context)
                    let drawn = NSMutableAttributedString(attributedString: strut)
                    drawn.append(line)
                    drawn.draw(at: CGPoint(x: left, y: lineTop + halfLeading))
                }
                x += box + border
            }
        }

        // The grid itself, stroked down the middle of each border box.
        context.setStrokeColor(PlatformColor.gfm(palette.border).cgColor)
        context.setLineWidth(border)
        var gx = border / 2
        context.move(to: CGPoint(x: gx, y: 0)); context.addLine(to: CGPoint(x: gx, y: total.height))
        for w in columnBoxes {
            gx += w + border
            context.move(to: CGPoint(x: gx, y: 0)); context.addLine(to: CGPoint(x: gx, y: total.height))
        }
        var gy = border / 2
        context.move(to: CGPoint(x: 0, y: gy)); context.addLine(to: CGPoint(x: total.width, y: gy))
        for r in 0..<grid.rowCount {
            gy += grid.rowHeights[r] + border
            context.move(to: CGPoint(x: 0, y: gy)); context.addLine(to: CGPoint(x: total.width, y: gy))
        }
        context.strokePath()
    }

    /// `code { padding: .2em .4em; border-radius: 6px; background: … }` — the
    /// pill behind each piece of code on `line`, as the live editor paints it
    /// (`drawInlineCodePills`): the code face's own box plus `.2em` above and
    /// below, centred on the line, across the padding the kerning reserves
    /// either side. A span split over two lines is two pills, the leading
    /// padding on the first and the trailing on the last — CSS's
    /// `box-decoration-break: slice`.
    private static func drawCodePills(in line: NSAttributedString, left: CGFloat, lineTop: CGFloat,
                                      theme: EditorTheme, palette: GFMPalette, context: CGContext) {
        let m = theme.metrics
        func x(_ index: Int) -> CGFloat {
            left + line.attributedSubstring(from: NSRange(location: 0, length: index)).size().width
        }
        line.enumerateAttribute(inlineCodeAttribute, in: NSRange(location: 0, length: line.length)) {
            value, span, _ in
            guard value != nil, span.length > 0 else { return }
            var start = span.location
            if start > 0, line.attribute(GFMTableGeometry.codePaddingAttribute,
                                         at: start - 1, effectiveRange: nil) != nil {
                start -= 1
            }
            let size = (line.attribute(.font, at: span.location, effectiveRange: nil) as? PlatformFont)?
                .pointSize ?? m.codeSize
            let height = min(m.bodyLineHeight, size * 1.56)
            let rect = CGRect(x: x(start), y: lineTop + (m.bodyLineHeight - height) / 2,
                              width: x(NSMaxRange(span)) - x(start), height: height)
            guard rect.width > 0 else { return }
            PlatformDraw.fill(rect, .gfm(palette.inlineCodeBackground), radius: m.codeRadius,
                              roundTop: true, roundBottom: true, in: context)
        }
    }

    /// How cell `c` of row `r` is aligned: as its column declares, or — with
    /// nothing declared — centred in the header, as the page centres a `th`,
    /// and from the left everywhere else. The picture set every header from the
    /// left: no height could see it, and every screenshot did.
    private static func alignment(of c: Int, row r: Int, in grid: GFMTableGrid) -> GFMTableLayout.Alignment {
        let declared = grid.table.declaredAlignments.indices.contains(c) ? grid.table.declaredAlignments[c] : nil
        return declared ?? (r == 0 ? .center : .left)
    }

    /// A no-break space in `font` whose kerning gives its advance back: no
    /// width, and the row's font on the line.
    private static func strut(_ font: PlatformFont) -> NSAttributedString {
        let space = NSAttributedString(string: "\u{00A0}", attributes: [.font: font])
        return NSAttributedString(string: "\u{00A0}",
                                  attributes: [.font: font, .kern: -space.size().width])
    }

}

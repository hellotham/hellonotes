//
//  TableImageRenderer.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  Draws a GFM pipe table as an aligned grid for the editor's block-embed
//  renderer. Reuses the same "render a block to an image, drawn in place of its
//  concealed source" path as math / Mermaid / images, so a table reads as a
//  real grid and reveals its Markdown source when the caret enters it.
//  Main-actor (uses text measurement + a drawing context). Cross-platform via
//  `PlatformImageKit` (top-left, y-down).
//
//  This file now owns *pixels only*. Which cells, in which columns, how wide
//  and how tall come from `GFMTableGeometry` in the editor package, because the
//  Preview draws the same table as a `<table>` and the only way two engines
//  agree is to measure from one table of numbers. Two things it used to decide
//  for itself, and got wrong both times:
//
//  * The grid lines were stroked *inside* the row heights, so a table came out
//    one hairline per row shorter than the page's `border-collapse: collapse`
//    — 3pt on the commonest table there is, and growing with every row.
//  * `components(separatedBy: "|")` split on escaped pipes too, so `| f\|oo |`
//    became two columns instead of one and the whole grid was a different width.
//

import CoreGraphics
import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import MarkdownCore

@MainActor
enum TableImageRenderer {

    static func image(source: String, maxWidth: CGFloat, fontSize: CGFloat = 15, isDark: Bool) -> PlatformImage? {
        let theme = EditorTheme(fontSize: fontSize)
        // Fitted, not natural: a table too wide for the pane shrinks its
        // columns and wraps its cells the way a browser does. It used to be
        // drawn at its natural width and the whole bitmap scaled down, which
        // makes an over-wide table *shorter* where the page makes it taller —
        // the two moved in opposite directions and the gap grew with the
        // overflow. `GFMTableGeometry.fitted` is where that layout lives, so
        // the parity sweep can know this picture's height without drawing it.
        guard let grid = GFMTableGeometry.fitted(source: source, theme: theme,
                                                 maxWidth: maxWidth) else { return nil }
        let m = theme.metrics
        let padX = m.cellPadX, border = m.hairline

        // Exact GitHub github-markdown-css table palette, so the editor's grid
        // matches the Preview's <table> in both appearances:
        //   fg   --fgColor-default   #1f2328 / #f0f6fc
        //   grid --borderColor-default #d1d9e0 / #3d444d
        //   zebra --bgColor-muted    #f6f8fa / #151b23  (tr:nth-child(2n))
        // GitHub has no header background band — the header is just semibold and
        // sits on the default (canvas) row like every odd row.
        let text: PlatformColor = isDark ? .hexColor(0xf0f6fc) : .hexColor(0x1f2328)
        let gridColor: PlatformColor = isDark ? .hexColor(0x3d444d) : .hexColor(0xd1d9e0)
        let zebraBG: PlatformColor = isDark ? .hexColor(0x151b23) : .hexColor(0xf6f8fa)

        // Column and row *box* extents, borders included. A collapsed border is
        // a box of its own — the cells sit between them, which is why the sums
        // below start at one border and step by one after every track.
        let columnBoxes: [CGFloat] = grid.columnTextWidths.map { $0 + 2 * padX }
        let total = grid.naturalSize
        guard total.width >= 1, total.height >= 1 else { return nil }

        /// The top of row `r`, over rows that are no longer all one height.
        func top(_ r: Int) -> CGFloat {
            border + grid.rowHeights[..<r].reduce(0) { $0 + $1 + border }
        }
        let natural = PlatformImageKit.image(size: total) { ctx in
            // Zebra striping: GitHub fills `tr:nth-child(2n)` with --bgColor-muted.
            // Counting the header as child 1, the striped rows are the 2nd, 4th…
            // children — i.e. odd row indices. Even rows keep the default canvas
            // background (left transparent so the grid sits on the editor's own).
            ctx.setFillColor(zebraBG.cgColor)
            for r in 0..<grid.rowCount where r % 2 == 1 {
                ctx.fill(CGRect(x: 0, y: top(r), width: total.width, height: grid.rowHeights[r]))
            }

            // Cell text (top-left origin, y grows downward).
            for (r, row) in grid.rows.enumerated() {
                let y = top(r)
                var x = border
                for (c, cell) in row.enumerated() where c < columnBoxes.count {
                    let attributed = NSAttributedString(
                        string: cell, attributes: [.font: grid.font(row: r), .foregroundColor: text])
                    let size = attributed.size()
                    let boxWidth = columnBoxes[c]
                    let tx: CGFloat
                    switch grid.alignments.indices.contains(c) ? grid.alignments[c] : .left {
                    case .left:   tx = x + padX
                    case .right:  tx = x + boxWidth - padX - size.width
                    case .center: tx = x + (boxWidth - size.width) / 2
                    }
                    // The cell's text box, which is what wraps. Its height is
                    // the row's, less the padding, so a wrapped cell fills the
                    // taller row instead of being clipped to one line.
                    let cellWidth = max(1, boxWidth - 2 * padX)
                    let wraps = size.width > cellWidth
                    let drawn = wraps ? cellWidth : size.width
                    let textHeight = grid.rowHeights[r] - 2 * m.cellPadY
                    let ty = wraps ? y + m.cellPadY : y + (grid.rowHeights[r] - size.height) / 2
                    attributed.draw(in: CGRect(x: wraps ? x + padX : tx, y: ty,
                                               width: drawn,
                                               height: wraps ? textHeight : size.height))
                    x += boxWidth + border
                }
            }

            // The grid itself, stroked down the middle of each border box.
            ctx.setStrokeColor(gridColor.cgColor)
            ctx.setLineWidth(border)
            var gx = border / 2
            ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: total.height))
            for w in columnBoxes {
                gx += w + border
                ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: total.height))
            }
            var gy = border / 2
            ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: total.width, y: gy))
            for r in 0..<grid.rowCount {
                gy += grid.rowHeights[r] + border
                ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: total.width, y: gy))
            }
            ctx.strokePath()
        }
        // No scaling: the grid was measured at the width it is drawn at, so the
        // picture is already the size the editor reserved for it.
        return natural
    }

}

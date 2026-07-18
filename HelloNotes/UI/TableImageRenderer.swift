//
//  TableImageRenderer.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  Renders a GFM pipe table to an aligned-grid image for the editor's
//  block-embed renderer. Reuses the same "render a block to an image, drawn
//  in place of its concealed source" path as math / Mermaid / images, so a
//  table reads as a real grid and reveals its Markdown source when the caret
//  enters it. Main-actor (uses text measurement + a drawing context).
//  Cross-platform via `PlatformImageKit` (top-left, y-down).
//

import CoreGraphics
import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
enum TableImageRenderer {
    private enum Align { case left, center, right }
    // GitHub's github-markdown-css: `th, td { padding: 6px 13px }`.
    private static let cellPadX: CGFloat = 13
    private static let cellPadY: CGFloat = 6

    static func image(source: String, maxWidth: CGFloat, fontSize: CGFloat = 15, isDark: Bool) -> PlatformImage? {
        let lines = source.components(separatedBy: "\n").filter { $0.contains("|") }
        guard lines.count >= 2 else { return nil }

        let rows = lines.map(cells)
        // Row 1 is the delimiter (`|:---|`); its cells give per-column alignment.
        let aligns = rows[1].map(alignment)
        let bodyRows = [rows[0]] + rows.dropFirst(2)
        let columns = max(rows[0].count, aligns.count)
        guard columns > 0 else { return nil }

        // Exact GitHub github-markdown-css table palette, so the editor's grid
        // matches the Preview's <table> in both appearances:
        //   fg   --fgColor-default   #1f2328 / #f0f6fc
        //   grid --borderColor-default #d1d9e0 / #3d444d
        //   zebra --bgColor-muted    #f6f8fa / #151b23  (tr:nth-child(2n))
        // GitHub has no header background band — the header is just semibold and
        // sits on the default (canvas) row like every odd row.
        let text: PlatformColor = isDark ? .hexColor(0xf0f6fc) : .hexColor(0x1f2328)
        let grid: PlatformColor = isDark ? .hexColor(0x3d444d) : .hexColor(0xd1d9e0)
        let zebraBG: PlatformColor = isDark ? .hexColor(0x151b23) : .hexColor(0xf6f8fa)
        let body = PlatformFont.appSystem(fontSize)
        let bold = PlatformFont.appSystem(fontSize, weight: .bold)

        // Measure natural column widths, then scale down to fit maxWidth.
        func attr(_ s: String, _ f: PlatformFont) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: text])
        }
        var colW = [CGFloat](repeating: 0, count: columns)
        var rowH = [CGFloat](repeating: 0, count: bodyRows.count)
        for (r, row) in bodyRows.enumerated() {
            let f = r == 0 ? bold : body
            for c in 0..<columns {
                let s = c < row.count ? row[c] : ""
                let size = attr(s, f).size()
                colW[c] = max(colW[c], ceil(size.width) + cellPadX * 2)
                rowH[r] = max(rowH[r], ceil(size.height) + cellPadY * 2)
            }
        }
        var totalW = colW.reduce(0, +)
        guard totalW > 0 else { return nil }
        var scale: CGFloat = 1
        if totalW > maxWidth { scale = maxWidth / totalW; colW = colW.map { $0 * scale }; totalW *= scale }
        let totalH = rowH.reduce(0, +)

        return PlatformImageKit.image(size: CGSize(width: ceil(totalW), height: ceil(totalH))) { ctx in
            // Zebra striping: GitHub fills `tr:nth-child(2n)` with --bgColor-muted.
            // Counting the header as child 1, the striped rows are the 2nd, 4th…
            // children — i.e. odd indices in `bodyRows` ([header, data1, data2…]).
            // Odd rows keep the default canvas background (left transparent so the
            // grid sits on the editor's own canvas).
            ctx.setFillColor(zebraBG.cgColor)
            var stripeY: CGFloat = 0
            for (r, _) in bodyRows.enumerated() {
                if r % 2 == 1 {
                    ctx.fill(CGRect(x: 0, y: stripeY, width: totalW, height: rowH[r]))
                }
                stripeY += rowH[r]
            }

            // Cell text (top-left origin, y grows downward).
            var y: CGFloat = 0
            for (r, row) in bodyRows.enumerated() {
                var x: CGFloat = 0
                for c in 0..<columns {
                    let s = c < row.count ? row[c] : ""
                    let a = attr(s, r == 0 ? bold : body)
                    let sz = a.size()
                    let colWidth = colW[c]
                    let align = c < aligns.count ? aligns[c] : .left
                    let tx: CGFloat
                    switch align {
                    case .left:   tx = x + cellPadX
                    case .right:  tx = x + colWidth - cellPadX - sz.width * scale
                    case .center: tx = x + (colWidth - sz.width * scale) / 2
                    }
                    let ty = y + (rowH[r] - sz.height) / 2
                    a.draw(in: CGRect(x: tx, y: ty, width: max(1, colWidth - cellPadX), height: sz.height))
                    x += colWidth
                }
                y += rowH[r]
            }

            // Grid lines.
            ctx.setStrokeColor(grid.cgColor)
            ctx.setLineWidth(1)
            var gx: CGFloat = 0.5
            ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: totalH))
            for w in colW { gx += w; ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: totalH)) }
            var gy: CGFloat = 0.5
            ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: totalW, y: gy))
            for h in rowH { gy += h; ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: totalW, y: gy)) }
            ctx.strokePath()
        }
    }

    /// Split a table line into trimmed cell strings (dropping the outer pipes).
    private static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignment(_ delimiterCell: String) -> Align {
        let c = delimiterCell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        return .left
    }
}

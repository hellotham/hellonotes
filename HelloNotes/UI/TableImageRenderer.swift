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
//  enters it. Main-actor (uses AppKit text measurement + lockFocus).
//

#if os(macOS)
import AppKit

@MainActor
enum TableImageRenderer {
    private enum Align { case left, center, right }
    private static let cellPadX: CGFloat = 10
    private static let cellPadY: CGFloat = 5

    static func image(source: String, maxWidth: CGFloat, isDark: Bool) -> NSImage? {
        let lines = source.components(separatedBy: "\n").filter { $0.contains("|") }
        guard lines.count >= 2 else { return nil }

        let rows = lines.map(cells)
        // Row 1 is the delimiter (`|:---|`); its cells give per-column alignment.
        let aligns = rows[1].map(alignment)
        let bodyRows = [rows[0]] + rows.dropFirst(2)
        let columns = max(rows[0].count, aligns.count)
        guard columns > 0 else { return nil }

        let text: NSColor = isDark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        let grid: NSColor = isDark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.18)
        let headerBG: NSColor = isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05)
        let body = NSFont.systemFont(ofSize: 13)
        let bold = NSFont.boldSystemFont(ofSize: 13)

        // Measure natural column widths, then scale down to fit maxWidth.
        func attr(_ s: String, _ f: NSFont) -> NSAttributedString {
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

        let image = NSImage(size: NSSize(width: ceil(totalW), height: ceil(totalH)))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // Header background band.
        headerBG.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: totalH - rowH[0], width: totalW, height: rowH[0])).fill()

        // Cell text.
        var y = totalH
        for (r, row) in bodyRows.enumerated() {
            y -= rowH[r]
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
                a.draw(in: NSRect(x: tx, y: ty, width: max(1, colWidth - cellPadX), height: sz.height))
                x += colWidth
            }
        }

        // Grid lines.
        ctx.setStrokeColor(grid.cgColor)
        ctx.setLineWidth(1)
        var gx: CGFloat = 0.5
        ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: totalH))
        for w in colW { gx += w; ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: totalH)) }
        var gy: CGFloat = 0.5
        ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: totalW, y: gy))
        for h in rowH.reversed() { gy += h; ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: totalW, y: gy)) }
        ctx.strokePath()

        return image
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
#endif

//
//  MathImageRenderer.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  Renders LaTeX (`$…$` / `$$…$$`) to an NSImage via SwiftMath (Latin Modern
//  math font, no WebView). This is HelloNotes' own math bridge, built directly
//  on SwiftMath. Main-actor only (SwiftMath lays out an NSView).
//

#if os(macOS)
import AppKit
import SwiftMath

@MainActor
enum MathImageRenderer {
    private static var cache: [String: NSImage] = [:]

    /// Render `latex` at `fontSize` in `color`, cropped to its true ink
    /// width. Returns nil for empty or unrenderable input.
    static func image(latex: String, fontSize: CGFloat, color: NSColor) -> NSImage? {
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let key = "\(Int(fontSize))\u{1}\(fingerprint(color))\u{1}\(source)"
        if let cached = cache[key] { return cached }

        let label = MTMathUILabel()
        label.latex = source
        label.fontSize = fontSize
        label.textColor = color
        label.textAlignment = .left
        label.labelMode = .text
        if let font = MTFontManager().font(withName: "latinmodern-math", size: fontSize) {
            label.font = font
        }
        label.layoutSubtreeIfNeeded()

        guard let displayList = label.displayList else { return nil }
        let exactWidth = displayList.width
        let exactHeight = displayList.ascent + displayList.descent
        // SwiftMath yields 0×0 for unsupported glyphs; lockFocus crashes on
        // zero dimensions, so bail.
        guard exactWidth > 0, exactHeight > 0 else { return nil }

        let isShort = source.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
        let canvasHeight = exactHeight + (isShort ? 1 : 0)

        // Advance width clips slanted glyphs' ink overhang; render with slack
        // then crop to the measured ink edge.
        let rightSlack = ceil(fontSize)
        let probeWidth = ceil(exactWidth) + rightSlack
        guard let probeRep = renderRep(label, size: CGSize(width: probeWidth, height: canvasHeight)),
              let probeCG = probeRep.cgImage else { return nil }

        let inkRight = inkRightEdge(probeCG, widthInPoints: probeWidth) ?? exactWidth
        let finalWidth = max(ceil(exactWidth), ceil(inkRight))
        let finalSize = CGSize(width: finalWidth, height: canvasHeight)

        let pxPerPoint = CGFloat(probeCG.width) / probeWidth
        let cropPx = min(probeCG.width, Int((finalWidth * pxPerPoint).rounded()))
        guard cropPx > 0,
              let cropped = probeCG.cropping(to: CGRect(x: 0, y: 0, width: cropPx, height: probeCG.height))
        else { return nil }

        let rep = NSBitmapImageRep(cgImage: cropped)
        rep.size = finalSize
        let image = NSImage(size: finalSize)
        image.addRepresentation(rep)

        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }

    private static func renderRep(_ label: MTMathUILabel, size: CGSize) -> NSBitmapImageRep? {
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep
    }

    private static func fingerprint(_ color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        let r = UInt32(max(0, min(255, Int(rgb.redComponent * 255))))
        let g = UInt32(max(0, min(255, Int(rgb.greenComponent * 255))))
        let b = UInt32(max(0, min(255, Int(rgb.blueComponent * 255))))
        return (r << 16) | (g << 8) | b
    }

    private static func inkRightEdge(_ image: CGImage, widthInPoints: CGFloat) -> CGFloat? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, widthInPoints > 0 else { return nil }
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var maxX = -1
        for y in 0..<h {
            let row = y * bytesPerRow
            var x = w - 1
            while x > maxX {
                if data[row + x * 4 + 3] > 10 { maxX = x; break }
                x -= 1
            }
        }
        guard maxX >= 0 else { return nil }
        return (CGFloat(maxX) + 1) * widthInPoints / CGFloat(w)
    }
}
#endif

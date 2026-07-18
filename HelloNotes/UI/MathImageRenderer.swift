//
//  MathImageRenderer.swift
//  HelloNotes
//
//  Created by Chris Tham on 17/7/2026.
//
//  Renders LaTeX (`$…$` / `$$…$$`) to a `PlatformImage` via SwiftMath (Latin
//  Modern math font, no WebView). This is HelloNotes' own math bridge, built
//  directly on SwiftMath. Main-actor only (SwiftMath lays out an MTView).
//  Cross-platform: the view→image step goes through `PlatformImageKit`.
//

import CoreGraphics
import SwiftMath
import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
enum MathImageRenderer {
    private static var cache: [String: PlatformImage] = [:]

    /// Render `latex` at `fontSize` in `color`, cropped to its true ink
    /// width. Returns nil for empty or unrenderable input.
    static func image(latex: String, fontSize: CGFloat, color: PlatformColor) -> PlatformImage? {
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
        forceLayout(label)

        guard let displayList = label.displayList else { return nil }
        let exactWidth = displayList.width
        let exactHeight = displayList.ascent + displayList.descent
        // SwiftMath yields 0×0 for unsupported glyphs; a zero-size render is
        // meaningless, so bail.
        guard exactWidth > 0, exactHeight > 0 else { return nil }

        let isShort = source.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
        let canvasHeight = exactHeight + (isShort ? 1 : 0)

        // Advance width clips slanted glyphs' ink overhang; render with slack
        // then crop to the measured ink edge.
        let rightSlack = ceil(fontSize)
        let probeWidth = ceil(exactWidth) + rightSlack
        guard let probeCG = renderCG(label, size: CGSize(width: probeWidth, height: canvasHeight)) else { return nil }

        let inkRight = inkRightEdge(probeCG, widthInPoints: probeWidth) ?? exactWidth
        let finalWidth = max(ceil(exactWidth), ceil(inkRight))
        let finalSize = CGSize(width: finalWidth, height: canvasHeight)

        let pxPerPoint = CGFloat(probeCG.width) / probeWidth
        let cropPx = min(probeCG.width, Int((finalWidth * pxPerPoint).rounded()))
        guard cropPx > 0,
              let cropped = probeCG.cropping(to: CGRect(x: 0, y: 0, width: cropPx, height: probeCG.height))
        else { return nil }

        let image = PlatformImageKit.image(cgImage: cropped, size: finalSize)

        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// Force SwiftMath to lay out (populating `displayList`).
    private static func forceLayout(_ label: MTMathUILabel) {
        #if canImport(AppKit)
        label.layoutSubtreeIfNeeded()
        #else
        label.setNeedsLayout()
        label.layoutIfNeeded()
        #endif
    }

    /// Render the label at `size` to a CGImage (top-left origin, upright).
    private static func renderCG(_ label: MTMathUILabel, size: CGSize) -> CGImage? {
        label.frame = CGRect(origin: .zero, size: size)
        forceLayout(label)
        return PlatformImageKit.cgImage(of: label, scale: 2)
    }

    private static func fingerprint(_ color: PlatformColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(AppKit)
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let ri = UInt32(max(0, min(255, Int(r * 255))))
        let gi = UInt32(max(0, min(255, Int(g * 255))))
        let bi = UInt32(max(0, min(255, Int(b * 255))))
        return (ri << 16) | (gi << 8) | bi
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

//
//  PlatformDraw.swift
//  MarkdownEditor
//
//  Cross-platform CoreGraphics helpers so the custom text-layout fragment can
//  draw its chrome (bullets, callout bands, heading rules, checkboxes, embeds)
//  identically on macOS (AppKit) and iOS (UIKit). Text fragments draw into a
//  y-down CGContext on both platforms; images are the only thing that needs an
//  explicit vertical flip.
//

import CoreGraphics
import MarkdownCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

enum PlatformDraw {
    /// A tinted SF Symbol as a `CGImage`, ready to draw with `image(_:in:context:)`.
    nonisolated static func symbol(_ name: String, pointSize: CGFloat, color: PlatformColor) -> CGImage? {
        #if canImport(AppKit)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(hierarchicalColor: color))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let base = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        // SF Symbol images can lack a backing `.cgImage`; render to a bitmap.
        let renderer = UIGraphicsImageRenderer(size: base.size)
        return renderer.image { _ in base.draw(at: .zero) }.cgImage
        #endif
    }

    /// The `CGImage` backing a rendered `PlatformImage` (math/table/embed).
    nonisolated static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        if let cg = image.cgImage { return cg }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(at: .zero) }.cgImage
        #endif
    }

    /// Draw a `CGImage` upright inside a y-down (text-layout) CGContext.
    nonisolated static func image(_ cgImage: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Fill a rectangle with a platform colour.
    nonisolated static func fill(_ rect: CGRect, _ color: PlatformColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }

    /// Fill an ellipse inscribed in `rect`.
    nonisolated static func fillEllipse(_ rect: CGRect, _ color: PlatformColor, in context: CGContext) {
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
    }

    /// Fill a rectangle whose top and/or bottom corners are rounded — a code
    /// block's background, which is painted a line at a time because each line
    /// of it is its own layout fragment, so only the first and last round.
    nonisolated static func fill(_ rect: CGRect, _ color: PlatformColor, radius: CGFloat,
                                 roundTop: Bool, roundBottom: Bool, in context: CGContext) {
        let r = min(radius, min(rect.width, rect.height) / 2)
        guard r > 0, roundTop || roundBottom else { return fill(rect, color, in: context) }
        let top = roundTop ? r : 0, bottom = roundBottom ? r : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + top, y: rect.minY), radius: top)
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top), radius: top)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        path.closeSubpath()
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath()
    }

    /// Stroke an ellipse inscribed in `rect`.
    nonisolated static func strokeEllipse(_ rect: CGRect, _ color: PlatformColor, lineWidth: CGFloat, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
    }
}

extension PlatformColor {
    /// A `GFMPalette.Ink` as a platform colour.
    nonisolated static func gfm(_ ink: GFMPalette.Ink) -> PlatformColor {
        #if canImport(AppKit)
        return NSColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha)
        #else
        return UIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha)
        #endif
    }

    /// A palette colour that follows the appearance, chosen by `pick`.
    ///
    /// Dynamic rather than resolved once: the editor's text storage outlives
    /// any single appearance, and a note open while the system flips to dark
    /// has to change colour with it — which a baked sRGB value cannot do.
    nonisolated static func gfm(_ pick: @escaping @Sendable (GFMPalette) -> GFMPalette.Ink) -> PlatformColor {
        #if canImport(AppKit)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return .gfm(pick(.of(isDark: isDark)))
        }
        #else
        return UIColor { traits in
            .gfm(pick(.of(isDark: traits.userInterfaceStyle == .dark)))
        }
        #endif
    }
}

/// Cross-platform semantic colours used by the fragment chrome.
extension PlatformColor {
    /// This colour as a CSS `rgba()`, alpha included — the system fills the
    /// editor draws with are semi-transparent, and flattening them would put a
    /// different grey behind Preview's code blocks than behind Edit's.
    nonisolated var cssColor: String {
        #if canImport(AppKit)
        let resolved = usingColorSpace(.sRGB) ?? NSColor.labelColor.usingColorSpace(.sRGB)
        guard let resolved else { return "currentColor" }
        #else
        let resolved = self
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let channel = { (v: CGFloat) in Int((v * 255).rounded()) }
        return "rgba(\(channel(r)), \(channel(g)), \(channel(b)), \(String(format: "%.3f", Double(a))))"
    }

    /// `--borderColor-default` — the h1/h2 rule, `hr`, the blockquote bar and
    /// the table grid, all of which the Preview draws in this exact colour.
    nonisolated static var editorSeparator: PlatformColor { .gfm(\.border) }
    /// `pre { background-color: var(--bgColor-muted) }` — the code block box.
    nonisolated static var editorCodeBackground: PlatformColor { .gfm(\.codeBackground) }
    /// `code { background-color: var(--bgColor-neutral-muted) }` — the inline pill.
    nonisolated static var editorInlineCodeBackground: PlatformColor { .gfm(\.inlineCodeBackground) }
    nonisolated static var editorLabel: PlatformColor {
        #if canImport(AppKit)
        return .labelColor
        #else
        return .label
        #endif
    }
}

extension NSTextLayoutManager {
    /// Invalidate TextKit 2 layout for a character range. Attribute-only styling
    /// (e.g. concealment shrinking a marker run's font) does not trigger a
    /// re-layout on its own, so a freshly-styled span keeps its old width until
    /// some later edit re-lays it out — this forces it. Shared by the macOS and
    /// iOS text views' progressive-styling paths.
    func invalidateLayout(charactersIn range: NSRange) {
        guard let cm = textContentManager,
              let start = cm.location(cm.documentRange.location, offsetBy: range.location),
              let end = cm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        invalidateLayout(for: textRange)
    }
}

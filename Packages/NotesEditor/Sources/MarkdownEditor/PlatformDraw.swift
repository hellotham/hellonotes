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

    /// Stroke an ellipse inscribed in `rect`.
    nonisolated static func strokeEllipse(_ rect: CGRect, _ color: PlatformColor, lineWidth: CGFloat, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)
    }
}

/// Cross-platform semantic colours used by the fragment chrome.
extension PlatformColor {
    nonisolated static var editorSeparator: PlatformColor {
        #if canImport(AppKit)
        return .separatorColor
        #else
        return .separator
        #endif
    }
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

//
//  PlatformImageKit.swift
//  HelloNotes
//
//  Cross-platform image drawing for the editor's block-embed renderers (table,
//  math, Mermaid, transclusion card, code colours). The app-side renderers were
//  AppKit `NSImage`/`lockFocus` only; this helper lets a single body of drawing
//  code produce a `PlatformImage` (NSImage / UIImage) on both macOS and iOS.
//
//  Coordinate system: **top-left origin, y-down** on both platforms — macOS via
//  `lockFocusFlipped(true)`, iOS via `UIGraphicsImageRenderer` (already y-down).
//  With the platform graphics context made current, `NSAttributedString.draw`
//  renders upright on both, so the same geometry works everywhere.
//

import CoreGraphics
import MarkdownEditor   // PlatformImage / PlatformColor / PlatformFont typealiases

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

enum PlatformImageKit {

    /// Draw into an image of `size` using a top-left-origin, y-down context on
    /// both platforms. The platform graphics context is current inside `draw`,
    /// so `NSAttributedString.draw(in:)` and `.draw(with:options:)` render
    /// upright. Returns nil for a degenerate size.
    static func image(size: CGSize, opaque: Bool = false, _ draw: (CGContext) -> Void) -> PlatformImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        #if canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)   // top-left origin, upright text
        if let ctx = NSGraphicsContext.current?.cgContext {
            if opaque {
                ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            draw(ctx)
        }
        image.unlockFocus()
        return image
        #else
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = opaque
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rctx in draw(rctx.cgContext) }
        #endif
    }

    /// Wrap a `CGImage` as a `PlatformImage` sized to `size` points.
    static func image(cgImage: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
        #else
        let scale = size.width > 0 ? CGFloat(cgImage.width) / size.width : 1
        return UIImage(cgImage: cgImage, scale: max(scale, 1), orientation: .up)
        #endif
    }

    /// The natural point size of a `PlatformImage`.
    static func size(of image: PlatformImage) -> CGSize { image.size }

    /// Load an image file from disk (cross-platform).
    static func loadImage(contentsOf url: URL) -> PlatformImage? {
        #if canImport(AppKit)
        return NSImage(contentsOf: url)
        #else
        return UIImage(contentsOfFile: url.path)
        #endif
    }

    /// Downscale `image` to fit `maxWidth` (never upscales).
    ///
    /// Off-main-safe: the macOS path draws through a bitmap `CGContext` (thread-
    /// safe), NOT `NSImage.lockFocus` (main-thread-only). This matters because
    /// `BlockRenderAdapter` (a background `actor`) calls this off the main thread
    /// to scale rendered Mermaid/math/transclusion/image embeds.
    static func scaled(_ image: PlatformImage, maxWidth: CGFloat) -> PlatformImage {
        let natural = image.size
        guard natural.width > 0, natural.width > maxWidth else { return image }
        let ratio = maxWidth / natural.width
        let size = CGSize(width: maxWidth, height: natural.height * ratio)
        #if canImport(AppKit)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        // Preserve the source's pixel density so a retina render stays crisp.
        let density = max(1, CGFloat(cg.width) / natural.width)
        let pxW = max(1, Int((size.width * density).rounded()))
        let pxH = max(1, Int((size.height * density).rounded()))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard let scaledCG = ctx.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: scaledCG)
        rep.size = size
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
        #else
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        #endif
    }

    /// Render a laid-out view (e.g. `MTMathUILabel`) into a `CGImage` at
    /// `scale` device pixels per point. Main-actor: touches view/layer state.
    @MainActor
    static func cgImage(of view: PlatformView, scale: CGFloat = 2) -> CGImage? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        #if canImport(AppKit)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
        #else
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { ctx in view.layer.render(in: ctx.cgContext) }
        return image.cgImage
        #endif
    }
}

#if canImport(AppKit)
typealias PlatformView = NSView
#else
typealias PlatformView = UIView
#endif

extension PlatformColor {
    /// An opaque sRGB colour from a `0xRRGGBB` literal (GitHub's exact hex
    /// palette). sRGB so it matches the WKWebView Preview's colour space.
    static func hexColor(_ rgb: Int) -> PlatformColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        #if canImport(AppKit)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: 1)
        #endif
    }

    /// Cross-platform secondary label colour (`secondaryLabelColor` / `secondaryLabel`).
    static var appSecondaryLabel: PlatformColor {
        #if canImport(AppKit)
        return .secondaryLabelColor
        #else
        return .secondaryLabel
        #endif
    }
}

extension PlatformFont {
    /// This font with the bold trait added (falls back to itself).
    var boldVariant: PlatformFont {
        #if canImport(AppKit)
        let d = fontDescriptor.symbolicTraits.union(.bold)
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(d), size: pointSize) ?? self
        #else
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitBold)) else { return self }
        return UIFont(descriptor: d, size: pointSize)
        #endif
    }

    /// This font with the italic trait added (falls back to itself).
    var italicVariant: PlatformFont {
        #if canImport(AppKit)
        let d = fontDescriptor.symbolicTraits.union(.italic)
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(d), size: pointSize) ?? self
        #else
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic)) else { return self }
        return UIFont(descriptor: d, size: pointSize)
        #endif
    }

    /// System font of `size` (+ optional weight) — cross-platform.
    static func appSystem(_ size: CGFloat, weight: PlatformFontWeight = .regular) -> PlatformFont {
        #if canImport(AppKit)
        return NSFont.systemFont(ofSize: size, weight: weight)
        #else
        return UIFont.systemFont(ofSize: size, weight: weight)
        #endif
    }

    /// Monospaced system font — cross-platform.
    static func appMonospaced(_ size: CGFloat, weight: PlatformFontWeight = .regular) -> PlatformFont {
        #if canImport(AppKit)
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        #else
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        #endif
    }
}

#if canImport(AppKit)
typealias PlatformFontWeight = NSFont.Weight
#else
typealias PlatformFontWeight = UIFont.Weight
#endif

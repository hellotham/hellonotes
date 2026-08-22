//
//  EditorTheme.swift
//  MarkdownEditor
//
//  Maps MarkdownCore's semantic roles to platform fonts and colors. One
//  immutable value per editor; fonts are prebuilt and cached at init so the
//  styling hot path never constructs a font. Cross-platform by typealias —
//  the same theme drives the future iOS editor.
//

import MarkdownCore
import CoreGraphics
#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif

/// Immutable, Sendable (all stored properties are immutable platform
/// objects that are safe to read from any thread) — and nonisolated, so
/// the off-main open path can style with it.
nonisolated public struct EditorTheme: @unchecked Sendable {
    public let fontSize: CGFloat
    public let accent: PlatformColor

    /// The box model this theme is measured against — the same table the
    /// Preview's stylesheet is generated from. Every size below is derived
    /// from it rather than from a ratio written out here, because a ratio
    /// written out here is a ratio that can disagree with the stylesheet, and
    /// for a year it did: 1.7/1.4/1.2/1.1/1/1 against GitHub's
    /// 2/1.5/1.25/1/.875/.85, so an h1 was 26pt in Edit and 32pt in Preview.
    public let metrics: GFMBoxMetrics

    // Prebuilt fonts.
    let body: PlatformFont
    let bodyBold: PlatformFont
    let bodyItalic: PlatformFont
    let bodyBoldItalic: PlatformFont
    let mono: PlatformFont
    let monoSmall: PlatformFont
    let headings: [PlatformFont]        // levels 1…6
    /// Near-zero-size font used to conceal syntax markers (same-length
    /// attribute transform; see docs/implemented.md).
    let concealed: PlatformFont

    // Colors.
    let text: PlatformColor
    let secondary: PlatformColor
    let markerColor: PlatformColor
    let codeBackground: PlatformColor
    let highlightBackground: PlatformColor
    let brokenLink: PlatformColor

    public init(fontSize: CGFloat = 16, accent: PlatformColor? = nil) {
        self.fontSize = fontSize
        let metrics = GFMBoxMetrics(base: fontSize)
        self.metrics = metrics

        #if canImport(AppKit)
        let accentColor = accent ?? .controlAccentColor
        body = .systemFont(ofSize: fontSize)
        bodyBold = .boldSystemFont(ofSize: fontSize)
        bodyItalic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        bodyBoldItalic = NSFontManager.shared.convert(bodyBold, toHaveTrait: .italicFontMask)
        mono = .monospacedSystemFont(ofSize: metrics.codeSize, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: max(9, metrics.codeSize - 3), weight: .regular)
        text = .labelColor
        secondary = .secondaryLabelColor
        markerColor = .tertiaryLabelColor
        codeBackground = .quaternarySystemFill
        highlightBackground = accentColor.withAlphaComponent(0.28)
        brokenLink = .tertiaryLabelColor
        // GitHub's headings are semibold (600), not bold (700).
        headings = (1...6).map {
            .systemFont(ofSize: metrics.headingSize($0), weight: .semibold)
        }
        concealed = .systemFont(ofSize: 0.1)
        #else
        let accentColor = accent ?? .tintColor
        body = .systemFont(ofSize: fontSize)
        bodyBold = .boldSystemFont(ofSize: fontSize)
        bodyItalic = .italicSystemFont(ofSize: fontSize)
        bodyBoldItalic = {
            let d = UIFont.boldSystemFont(ofSize: fontSize).fontDescriptor
                .withSymbolicTraits([.traitBold, .traitItalic])
            return d.map { UIFont(descriptor: $0, size: fontSize) } ?? .boldSystemFont(ofSize: fontSize)
        }()
        mono = .monospacedSystemFont(ofSize: metrics.codeSize, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: max(9, metrics.codeSize - 3), weight: .regular)
        text = .label
        secondary = .secondaryLabel
        markerColor = .tertiaryLabel
        codeBackground = .quaternarySystemFill
        highlightBackground = accentColor.withAlphaComponent(0.28)
        brokenLink = .tertiaryLabel
        // GitHub's headings are semibold (600), not bold (700).
        headings = (1...6).map {
            .systemFont(ofSize: metrics.headingSize($0), weight: .semibold)
        }
        concealed = .systemFont(ofSize: 0.1)
        #endif
        self.accent = accentColor
    }

    /// The font a heading of `level` is drawn in. Public so a host can render
    /// chrome that has to sit flush with the document's own headings — the
    /// inline note title, for one — without duplicating the size ratios here
    /// and drifting from them.
    public func headingFont(level: Int) -> PlatformFont {
        headings[max(1, min(level, 6)) - 1]
    }

    /// A monospaced font at `size`. Inline code inherits its context's size in
    /// GitHub's stylesheet (`h1 code { font-size: inherit }`) and is 85% of the
    /// body size everywhere else; the editor used one fixed mono size for both,
    /// so `` `code` `` in an h1 shrank to body size in Edit and stayed heading-
    /// sized in Preview.
    func monoFont(matching font: PlatformFont?) -> PlatformFont {
        let current = font?.pointSize ?? fontSize
        // Body-sized text takes the 85% code size; anything else (a heading)
        // keeps its own size, which is what `inherit` does.
        let size = abs(current - fontSize) < 0.01 ? metrics.codeSize : current
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// GitHub tints h6 with the muted foreground; every other level takes the
    /// default text colour.
    func headingColor(level: Int) -> PlatformColor { level >= 6 ? secondary : text }
}

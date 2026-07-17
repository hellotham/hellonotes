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

    // Prebuilt fonts.
    let body: PlatformFont
    let bodyBold: PlatformFont
    let bodyItalic: PlatformFont
    let bodyBoldItalic: PlatformFont
    let mono: PlatformFont
    let monoSmall: PlatformFont
    let headings: [PlatformFont]        // levels 1…6
    /// Near-zero-size font used to conceal syntax markers (same-length
    /// attribute transform; see docs/editor-rewrite.md).
    let concealed: PlatformFont

    // Colors.
    let text: PlatformColor
    let secondary: PlatformColor
    let markerColor: PlatformColor
    let codeBackground: PlatformColor
    let highlightBackground: PlatformColor
    let brokenLink: PlatformColor

    public init(fontSize: CGFloat = 15, accent: PlatformColor? = nil) {
        self.fontSize = fontSize

        #if canImport(AppKit)
        let accentColor = accent ?? .controlAccentColor
        body = .systemFont(ofSize: fontSize)
        bodyBold = .boldSystemFont(ofSize: fontSize)
        bodyItalic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        bodyBoldItalic = NSFontManager.shared.convert(bodyBold, toHaveTrait: .italicFontMask)
        mono = .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: max(9, fontSize - 4), weight: .regular)
        text = .labelColor
        secondary = .secondaryLabelColor
        markerColor = .tertiaryLabelColor
        codeBackground = .quaternarySystemFill
        highlightBackground = accentColor.withAlphaComponent(0.28)
        brokenLink = .tertiaryLabelColor
        var sizes: [CGFloat] = [1.7, 1.4, 1.2, 1.1, 1.0, 1.0]
        headings = sizes.map { .boldSystemFont(ofSize: (fontSize * $0).rounded()) }
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
        mono = .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: max(9, fontSize - 4), weight: .regular)
        text = .label
        secondary = .secondaryLabel
        markerColor = .tertiaryLabel
        codeBackground = .quaternarySystemFill
        highlightBackground = accentColor.withAlphaComponent(0.28)
        brokenLink = .tertiaryLabel
        var sizes: [CGFloat] = [1.7, 1.4, 1.2, 1.1, 1.0, 1.0]
        headings = sizes.map { .boldSystemFont(ofSize: (fontSize * $0).rounded()) }
        concealed = .systemFont(ofSize: 0.1)
        #endif
        self.accent = accentColor
    }

    func headingFont(level: Int) -> PlatformFont {
        headings[max(1, min(level, 6)) - 1]
    }
}

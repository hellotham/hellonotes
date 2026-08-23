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
import GFMRender
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

    /// How small "concealed" is, and why it matters that it is *this* small.
    ///
    /// Concealment shrinks a marker rather than removing it, so the text keeps
    /// its coordinate system — but a shrunk glyph still has an advance, and the
    /// advances add up. At 0.1pt a concealed `](https://…/index.html)` was
    /// still 2.1pt wide, which pushed every word after it on that line 2.1pt
    /// right of where the Preview put them. The longer the URL, the bigger the
    /// shift. A tenth of that leaves the residual below a fifth of a point for
    /// any marker anyone would actually type.
    /// Public because the app's fidelity snapshot test asserts on it: the
    /// residual width of a concealed marker is the whole point of the number,
    /// and a test that cannot read it can only re-state the constant.
    public static let concealedSize: CGFloat = 0.01

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
        // `b, strong { font-weight: var(--base-text-weight-semibold, 600) }` —
        // semibold, not bold. The editor drew `**bold**` at 700 against the
        // Preview's 600: heavier, wider, and enough to move everything after it
        // on the line. Headings had already been corrected to 600; this is the
        // same rule, on the same stylesheet line, for inline emphasis.
        bodyBold = .systemFont(ofSize: fontSize, weight: .semibold)
        bodyItalic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        bodyBoldItalic = NSFontManager.shared.convert(bodyBold, toHaveTrait: .italicFontMask)
        mono = .monospacedSystemFont(ofSize: metrics.codeSize, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: max(9, metrics.codeSize - 3), weight: .regular)
        // GitHub's ink, not the system's. Preview has always painted the note
        // in these colours; the editor painted it in `labelColor` on the
        // window's own material, so switching mode changed the page's colour
        // as surely as its layout. See `GFMPalette`.
        text = .gfm(\.text)
        secondary = .gfm(\.muted)
        markerColor = .gfm(\.muted)
        codeBackground = .gfm(\.codeBackground)
        highlightBackground = accentColor.withAlphaComponent(0.28)
        brokenLink = .gfm(\.muted)
        // GitHub's headings are semibold (600), not bold (700).
        headings = (1...6).map {
            .systemFont(ofSize: metrics.headingSize($0), weight: .semibold)
        }
        concealed = .systemFont(ofSize: Self.concealedSize)
        #else
        let accentColor = accent ?? .tintColor
        body = .systemFont(ofSize: fontSize)
        // `b, strong { font-weight: 600 }` — see the AppKit branch above.
        bodyBold = .systemFont(ofSize: fontSize, weight: .semibold)
        bodyItalic = .italicSystemFont(ofSize: fontSize)
        bodyBoldItalic = {
            let semibold = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let d = semibold.fontDescriptor.withSymbolicTraits(
                semibold.fontDescriptor.symbolicTraits.union(.traitItalic))
            return d.map { UIFont(descriptor: $0, size: fontSize) } ?? semibold
        }()
        mono = .monospacedSystemFont(ofSize: metrics.codeSize, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: max(9, metrics.codeSize - 3), weight: .regular)
        // GitHub's ink, not the system's — see the AppKit branch above.
        text = .gfm(\.text)
        secondary = .gfm(\.muted)
        markerColor = .gfm(\.muted)
        codeBackground = .gfm(\.codeBackground)
        highlightBackground = accentColor.withAlphaComponent(0.28)
        brokenLink = .gfm(\.muted)
        // GitHub's headings are semibold (600), not bold (700).
        headings = (1...6).map {
            .systemFont(ofSize: metrics.headingSize($0), weight: .semibold)
        }
        concealed = .systemFont(ofSize: Self.concealedSize)
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

    /// This theme's colours, as CSS, so the Preview paints the note in the same
    /// ink the editor does.
    ///
    /// Resolved here rather than left to `prefers-color-scheme`: these are
    /// dynamic system colours, and the value that matters is the one the
    /// *editor* is currently drawing with. Leaving the page to decide for
    /// itself is how Preview came to paint GitHub's `#0d1117` canvas behind a
    /// note the editor was drawing on the window's own background.
    public func pagePalette(isDark: Bool) -> GFMRenderer.Palette {
        let gfm = GFMPalette.of(isDark: isDark)
        return GFMRenderer.Palette(
            text: gfm.text.css,
            muted: gfm.muted.css,
            // The *user's* accent for links, not GitHub's blue: it is a setting
            // they chose, and it is the colour the editor already draws a link
            // in. Everything else on this page is GitHub's.
            accent: resolving(isDark: isDark) { accent.cssColor },
            codeBackground: gfm.codeBackground.css,
            inlineCodeBackground: gfm.inlineCodeBackground.css,
            border: gfm.border.css,
            // Nothing: the note pane paints the canvas behind whichever
            // renderer is on screen, so the background belongs to neither of
            // them and cannot differ between them.
            canvas: nil)
    }

    /// `--borderColor-default` — the colour of an h1/h2 rule, an `hr`, a
    /// blockquote's bar and a table's grid. Public so chrome that has to sit
    /// flush with the document (the inline title's rule) draws the same line
    /// the fragment does, rather than one that merely looks similar.
    public var ruleColor: PlatformColor { .editorSeparator }

    /// The canvas a note is written on — the pane paints it, and both renderers
    /// sit on it.
    public static func canvas(isDark: Bool) -> PlatformColor {
        .gfm(GFMPalette.of(isDark: isDark).canvas)
    }

    /// Resolve dynamic colours against the appearance actually on screen.
    private func resolving<T>(isDark: Bool, _ body: () -> T) -> T {
        #if canImport(AppKit)
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        guard let appearance else { return body() }
        var out: T?
        appearance.performAsCurrentDrawingAppearance { out = body() }
        return out ?? body()
        #else
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        var out: T?
        traits.performAsCurrent { out = body() }
        return out ?? body()
        #endif
    }
}

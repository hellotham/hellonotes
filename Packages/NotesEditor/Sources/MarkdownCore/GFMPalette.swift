//
//  GFMPalette.swift
//  MarkdownCore
//
//  GitHub's Markdown colours, as numbers — the companion to `GFMBoxMetrics`,
//  and the other half of what the two renderers have to agree on.
//
//  The box model made Edit and Preview lay a note out identically. It said
//  nothing about ink, and they did not agree there either: Preview painted
//  GitHub's canvas (`#0d1117` in dark) in GitHub's text, link and border
//  colours, while the editor painted no canvas at all — the window's material
//  showed through — and drew in the system's `labelColor`. So switching mode
//  changed the colour of the page as surely as it changed the layout.
//
//  Both now read this. `EditorTheme` turns it into platform colours, the
//  fragment chrome draws its rules and bars from it, `GFMRenderer.page` emits
//  it as the stylesheet's own variables, and the note pane paints `canvas`
//  behind whichever renderer is on screen — so the background does not belong
//  to either of them and cannot differ between them.
//
//  Values transcribed from github-markdown-css, which is the same stylesheet
//  the Preview loads: if a number here is wrong, it is wrong in a way the
//  parity check can see.
//

import Foundation
import CoreGraphics

public struct GFMPalette: Sendable, Equatable {

    /// One colour, as sRGB components — platform-free so `MarkdownCore` stays
    /// Foundation-only and both renderers can build their own kind of colour
    /// from it.
    public struct Ink: Sendable, Equatable {
        public var red: Double, green: Double, blue: Double, alpha: Double

        /// `0xRRGGBB` with an optional alpha, which is how the stylesheet
        /// writes them (`#818b981f` is a 12% neutral).
        public init(_ hex: UInt32, alpha: Double = 1) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
            self.alpha = alpha
        }

        public var css: String {
            let channel = { (v: Double) in Int((v * 255).rounded()) }
            return "rgba(\(channel(red)), \(channel(green)), \(channel(blue)), "
                + String(format: "%.3f", alpha) + ")"
        }
    }

    /// `--bgColor-default` — the page the note is written on.
    public var canvas: Ink
    /// `--fgColor-default`.
    public var text: Ink
    /// `--fgColor-muted` — h6, blockquote text, the fence's language.
    public var muted: Ink
    /// `--fgColor-accent` — links.
    public var accent: Ink
    /// `--bgColor-muted` — the `pre` box.
    public var codeBackground: Ink
    /// `--bgColor-neutral-muted` — an inline `code` pill.
    public var inlineCodeBackground: Ink
    /// `--borderColor-default` — heading rules, `hr`, table grid, quote bars.
    public var border: Ink

    public static let light = GFMPalette(
        canvas: Ink(0xffffff),
        text: Ink(0x1f2328),
        muted: Ink(0x59636e),
        accent: Ink(0x0969da),
        codeBackground: Ink(0xf6f8fa),
        inlineCodeBackground: Ink(0x818b98, alpha: 0.122),   // #818b981f
        border: Ink(0xd1d9e0))

    public static let dark = GFMPalette(
        canvas: Ink(0x0d1117),
        text: Ink(0xf0f6fc),
        muted: Ink(0x9198a1),
        accent: Ink(0x4493f8),
        codeBackground: Ink(0x151b23),
        inlineCodeBackground: Ink(0x656c76, alpha: 0.2),     // #656c7633
        border: Ink(0x3d444d))

    public static func of(isDark: Bool) -> GFMPalette { isDark ? .dark : .light }
}

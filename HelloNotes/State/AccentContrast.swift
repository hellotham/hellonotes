//
//  AccentContrast.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/8/2026.
//
//  The WCAG colour maths behind the accent: how dark to push a tint before it
//  is legible as text, and which of black or white to put on top of it as a
//  fill label.
//
//  It exists as its own file because it used to live inside a
//  `#if os(macOS)` block in `AppearanceSettings`, written entirely in
//  `NSColor` — `blended(withFraction:of:)`, `redComponent`, `usingColorSpace`,
//  none of which UIKit has. So "Increase contrast" was a switch that iPad drew,
//  stored, and then ignored: `accentTextColor` returned the raw tint, and the
//  AAA target the toggle exists to select was never consulted on that platform.
//
//  The tempting fix is a UIKit transcription of the same eleven functions. That
//  is how the collection lifecycle drifted into two behaviours, so instead the
//  maths is written **once**, on plain sRGB triples that belong to no
//  framework, and each platform supplies three tiny adapters: read components,
//  build a colour, and build one that answers differently in dark mode. There
//  is no second copy to fall out of step, and the ratios are now testable
//  without a window.
//

import CoreGraphics
import SwiftUI
import MarkdownEditor   // PlatformColor

// MARK: - Framework-free colour

/// An sRGB colour as three components. Deliberately not a platform type: every
/// function below is pure arithmetic, so it runs identically on both platforms
/// and in a test with no UI at all.
struct SRGB: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let black = SRGB(red: 0, green: 0, blue: 0)
    static let white = SRGB(red: 1, green: 1, blue: 1)

    /// A neutral grey, for the window backgrounds contrast is measured against.
    static func grey(_ value: CGFloat) -> SRGB { SRGB(red: value, green: value, blue: value) }

    /// Linear interpolation toward `other`. The stand-in for AppKit's
    /// `blended(withFraction:of:)`, which is where the macOS-only-ness started.
    func blended(withFraction fraction: CGFloat, of other: SRGB) -> SRGB {
        let f = min(max(fraction, 0), 1)
        return SRGB(red: red + (other.red - red) * f,
                    green: green + (other.green - green) * f,
                    blue: blue + (other.blue - blue) * f)
    }

    /// WCAG 2.1 relative luminance.
    var luminance: CGFloat {
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG contrast ratio, 1…21. Symmetric, so argument order never matters.
    static func contrast(_ a: SRGB, _ b: SRGB) -> CGFloat {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Blend toward black (or white) in steps until the result meets `target`
    /// contrast against `background`.
    ///
    /// Stepwise rather than solved, because the answer has to stay recognisably
    /// *the user's accent* — the first blend that clears the bar is the closest
    /// one to what they picked. The `fraction < 1` bound is what stops a tint
    /// that can never reach the target (there is no 7:1 orange on white) from
    /// looping: it ends at pure black or white, which is legible even if it is
    /// no longer the accent.
    func readable(on background: SRGB, towardDark: Bool, target: CGFloat) -> SRGB {
        let end: SRGB = towardDark ? .black : .white
        var result = self
        var fraction: CGFloat = 0
        while SRGB.contrast(result, background) < target && fraction < 1 {
            fraction += 0.07
            result = blended(withFraction: fraction, of: end)
        }
        return result
    }

    /// The accent as it should appear *against* a light or dark ground:
    /// lightened on dark, slightly deepened on light, so one stored tint reads
    /// as vivid in both appearances.
    func contextAdjusted(isDark: Bool) -> SRGB {
        isDark ? blended(withFraction: 0.24, of: .white)
               : blended(withFraction: 0.08, of: .black)
    }

    /// Black or white — whichever is more legible on top of this colour.
    var labelOnTop: SRGB {
        SRGB.contrast(.white, self) >= SRGB.contrast(.black, self) ? .white : .black
    }
}

// MARK: - The three platform adapters

extension SRGB {
    /// The window background each appearance measures text contrast against.
    /// Not the real window colour (which is a material and has no single value)
    /// but the value the material resolves close to — the same two constants
    /// the macOS-only code used, kept so the Mac's output is unchanged.
    static func windowGround(isDark: Bool) -> SRGB { grey(isDark ? 0.12 : 0.98) }
}

extension PlatformColor {
    /// This colour's sRGB components.
    ///
    /// Via `CGColor` rather than each platform's component accessors: those
    /// trap on a colour that is not already in an RGB space (a pattern, a
    /// catalogue colour, `.tintColor`), and the accent can be any of those.
    var srgb: SRGB {
        #if canImport(AppKit)
        let converted = usingColorSpace(.sRGB)
        if let converted {
            return SRGB(red: converted.redComponent,
                        green: converted.greenComponent,
                        blue: converted.blueComponent)
        }
        #else
        // No `usingColorSpace` on UIKit, and none needed: `UIColor`'s
        // `cgColor` is already convertible, which is what the shared path
        // below does. The AppKit branch exists because `NSColor.cgColor` traps
        // on a colour that is not in an RGB space.
        #endif
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let c = cg.components, c.count >= 3 else {
            return .grey(0.5)
        }
        return SRGB(red: c[0], green: c[1], blue: c[2])
    }

    /// A concrete platform colour from components.
    static func fromSRGB(_ rgb: SRGB) -> PlatformColor {
        #if canImport(AppKit)
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        #else
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        #endif
    }

    /// A colour that resolves differently in light and dark.
    ///
    /// The one genuinely platform-shaped piece: AppKit asks an `NSAppearance`,
    /// UIKit asks a `UITraitCollection`. Both hand back a bool, and everything
    /// downstream of that bool is shared.
    static func adaptive(_ resolve: @escaping @Sendable (_ isDark: Bool) -> SRGB) -> PlatformColor {
        #if canImport(AppKit)
        return NSColor(name: nil) { appearance in
            fromSRGB(resolve(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
        }
        #else
        return UIColor { traits in
            fromSRGB(resolve(traits.userInterfaceStyle == .dark))
        }
        #endif
    }

    /// The system's own accent, for "multicolor".
    static var systemAccent: PlatformColor {
        #if canImport(AppKit)
        return .controlAccentColor
        #else
        return .tintColor
        #endif
    }
}

// MARK: - SwiftUI bridge

extension Color {
    /// A SwiftUI colour from a platform one. `Color(nsColor:)` and
    /// `Color(uiColor:)` are the same idea under two names, and spelling the
    /// branch out at every call site is how a theming decision turns into a
    /// platform decision.
    init(platform color: PlatformColor) {
        #if canImport(AppKit)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

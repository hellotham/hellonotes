//
//  AppearanceSettings.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  App-wide theming: light / dark / auto appearance, an accent (highlight)
//  colour like macOS Appearance settings, and a text-size scale. Persisted to
//  UserDefaults and applied at each window's root via `themedRoot`.
//

import SwiftUI

@MainActor
@Observable
final class AppearanceSettings {

    // MARK: Appearance mode

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "Auto"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        var symbol: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }
    }

    // MARK: Accent colour

    enum Accent: String, CaseIterable, Identifiable {
        case lavender, multicolor, blue, purple, pink, red, orange, yellow, green, graphite, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .multicolor: return "Multicolor"
            case .custom: return "Custom"
            case .lavender: return "Lavender"
            default: return rawValue.capitalized
            }
        }

        /// The base colour to tint with; `nil` for "multicolor" (follow the
        /// system accent) and for "custom" (the caller supplies it).
        var color: Color? {
            switch self {
            case .multicolor, .custom: return nil
            case .lavender: return AppearanceSettings.brandLavender
            case .blue: return .blue
            case .purple: return .purple
            case .pink: return .pink
            case .red: return .red
            case .orange: return .orange
            case .yellow: return .yellow
            case .green: return .green
            case .graphite: return Color(white: 0.5)
            }
        }

        /// A representative swatch colour for the picker (multicolor shows the
        /// system accent).
        var swatch: Color { color ?? .accentColor }
    }

    /// The app's signature lavender/mauve accent (the default).
    static let brandLavender = Color(.sRGB, red: 0.584, green: 0.459, blue: 0.804)

    // MARK: Stored settings

    var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode") } }
    var accent: Accent { didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accentChoice") } }
    var customAccent: Color { didSet { UserDefaults.standard.set(Self.hex(customAccent), forKey: "customAccentHex") } }
    /// 0.8 … 1.5, with 1.0 the default (middle of the slider).
    var textScale: Double { didSet { UserDefaults.standard.set(textScale, forKey: "textScale") } }

    static let minScale = 0.8
    static let maxScale = 1.5

    init() {
        let defaults = UserDefaults.standard
        mode = Mode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        accent = Accent(rawValue: defaults.string(forKey: "accentChoice") ?? "") ?? .lavender
        customAccent = Self.color(fromHex: defaults.string(forKey: "customAccentHex")) ?? Self.brandLavender
        let stored = defaults.double(forKey: "textScale")
        textScale = stored == 0 ? 1.0 : min(max(stored, Self.minScale), Self.maxScale)
    }

    // MARK: Derived

    var colorScheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The base accent colour the user chose, or `nil` for "multicolor"
    /// (follow the system accent).
    var baseAccent: Color? {
        switch accent {
        case .multicolor: return nil
        case .custom: return customAccent
        default: return accent.color
        }
    }

    /// The tint to apply app-wide. It *adapts to context*: the chosen accent is
    /// lightened on dark backgrounds and slightly deepened on light ones, so it
    /// stays vivid and legible in either appearance. `nil` follows the system.
    var accentColor: Color? {
        guard let base = baseAccent else { return nil }
        #if os(macOS)
        return Color(nsColor: Self.adaptiveNSColor(base))
        #else
        return base
        #endif
    }

    /// The current tint as a concrete colour, for previews/swatches.
    var resolvedAccent: Color { accentColor ?? .accentColor }

    #if os(macOS)
    /// The accent as a concrete (appearance-adaptive) NSColor — falls back to the
    /// system accent for "multicolor". Used for control fills / decorations.
    var editorAccentNSColor: NSColor {
        if let base = baseAccent { return Self.adaptiveNSColor(base) }
        return .controlAccentColor
    }

    /// The accent when used as *text* (links, selected labels): the adaptive
    /// accent, further adjusted until it clears the WCAG AA 4.5:1 ratio against
    /// the window background, so accent-coloured text stays legible in both
    /// appearances.
    var accentTextNSColor: NSColor {
        guard let base = baseAccent else { return .controlAccentColor }
        let solid = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let start = Self.contextAdjusted(solid, isDark: isDark)
            let bg: NSColor = isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.98, alpha: 1)
            return Self.readable(start, on: bg, towardDark: !isDark)
        }
    }

    /// The label colour to place *on top of* an accent fill (black or white,
    /// whichever contrasts better with the accent in the current appearance).
    var onAccentNSColor: NSColor {
        let base = baseAccent.map { NSColor($0).usingColorSpace(.sRGB) ?? NSColor($0) }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fill = base.map { Self.contextAdjusted($0, isDark: isDark) } ?? .controlAccentColor
            return Self.contrast(.white, fill) >= Self.contrast(.black, fill) ? .white : .black
        }
    }

    /// The accent as a legible text colour, or `nil` for "multicolor".
    var accentText: Color? { baseAccent == nil ? nil : Color(nsColor: accentTextNSColor) }
    var onAccent: Color { Color(nsColor: onAccentNSColor) }

    /// A dynamic NSColor that lightens `base` on dark backgrounds and deepens it
    /// slightly on light ones — the "adjusts depending on context" behaviour.
    static func adaptiveNSColor(_ base: Color) -> NSColor {
        let solid = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return contextAdjusted(solid, isDark: isDark)
        }
    }

    private static func contextAdjusted(_ solid: NSColor, isDark: Bool) -> NSColor {
        isDark ? (solid.blended(withFraction: 0.24, of: .white) ?? solid)
               : (solid.blended(withFraction: 0.08, of: .black) ?? solid)
    }

    // MARK: WCAG contrast helpers

    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Blend `color` toward black (or white) in steps until it meets `target`
    /// contrast against `bg`.
    static func readable(_ color: NSColor, on bg: NSColor, towardDark: Bool, target: CGFloat = 4.5) -> NSColor {
        let solid = color.usingColorSpace(.sRGB) ?? color
        let end: NSColor = towardDark ? .black : .white
        var result = solid
        var fraction: CGFloat = 0
        while contrast(result, bg) < target && fraction < 1 {
            fraction += 0.07
            result = solid.blended(withFraction: fraction, of: end) ?? result
        }
        return result
    }
    #endif

    /// Base editor font size (points) scaled by the text setting.
    var editorFontSize: CGFloat { 16 * textScale }

    /// Nearest Dynamic Type size for scaling SwiftUI chrome. 1.0 → `.large`
    /// (the system default).
    var dynamicTypeSize: DynamicTypeSize {
        switch textScale {
        case ..<0.86: return .xSmall
        case ..<0.95: return .small
        case ..<1.06: return .large
        case ..<1.16: return .xLarge
        case ..<1.30: return .xxLarge
        default: return .xxxLarge
        }
    }

    // MARK: - Colour <-> hex

    static func hex(_ color: Color) -> String {
        let (r, g, b, _) = rgba(color)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    static func color(fromHex hex: String?) -> Color? {
        guard var s = hex, s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    private static func rgba(_ color: Color) -> (Double, Double, Double, Double) {
        #if os(macOS)
        let native = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (Double(native.redComponent), Double(native.greenComponent),
                Double(native.blueComponent), Double(native.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #endif
    }
}

// MARK: - Root modifier

private struct ThemedRoot: ViewModifier {
    let settings: AppearanceSettings
    func body(content: Content) -> some View {
        content
            .tint(settings.accentColor)
            .preferredColorScheme(settings.colorScheme)
            .dynamicTypeSize(settings.dynamicTypeSize)
    }
}

extension View {
    /// Apply the app's appearance (accent tint, light/dark, text scale) at a
    /// window root.
    func themedRoot(_ settings: AppearanceSettings) -> some View {
        modifier(ThemedRoot(settings: settings))
    }
}

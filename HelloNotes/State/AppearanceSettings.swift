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

    var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
            applyWindowAppearance()
        }
    }
    var accent: Accent { didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accentChoice") } }
    var customAccent: Color { didSet { UserDefaults.standard.set(Self.hex(customAccent), forKey: "customAccentHex") } }
    /// 0.8 … 1.5, with 1.0 the default (middle of the slider).
    var textScale: Double { didSet { UserDefaults.standard.set(textScale, forKey: "textScale") } }
    /// Deepen the accent and raise the text-contrast target to WCAG AAA (7:1).
    var increaseContrast: Bool { didSet { UserDefaults.standard.set(increaseContrast, forKey: "increaseContrast") } }

    // MARK: Text width (decision 5 — reading is not editing)

    /// The measure used when *reading*: a fixed character count, centred,
    /// because line length is the whole point of reading comfortably.
    var readingWidth: ReadingWidth {
        didSet { UserDefaults.standard.set(readingWidth.rawValue, forKey: "readingWidth") }
    }

    /// How much of the pane *editing* uses. Full by default: the pane is the
    /// workspace, and nobody would accept a Markdown file rendered as a narrow
    /// ribbon down the middle of a code editor.
    var editorWidth: EditorWidth {
        didSet { UserDefaults.standard.set(editorWidth.rawValue, forKey: "editorWidth") }
    }

    /// An optional vertical guide while editing, in characters — a line you can
    /// see, like Xcode's page guide, *not* a wrap point. 0 is off.
    var wrapGuide: Int {
        didSet { UserDefaults.standard.set(wrapGuide, forKey: "wrapGuide") }
    }

    static let wrapGuideChoices = [0, 72, 80, 100]

    static let minScale = 0.8
    static let maxScale = 1.5

    init() {
        let defaults = UserDefaults.standard
        mode = Mode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        accent = Accent(rawValue: defaults.string(forKey: "accentChoice") ?? "") ?? .lavender
        customAccent = Self.color(fromHex: defaults.string(forKey: "customAccentHex")) ?? Self.brandLavender
        let stored = defaults.double(forKey: "textScale")
        textScale = stored == 0 ? 1.0 : min(max(stored, Self.minScale), Self.maxScale)
        increaseContrast = defaults.bool(forKey: "increaseContrast")
        readingWidth = ReadingWidth(rawValue: defaults.string(forKey: "readingWidth") ?? "") ?? .normal
        editorWidth = EditorWidth(rawValue: defaults.string(forKey: "editorWidth") ?? "") ?? .full
        wrapGuide = defaults.integer(forKey: "wrapGuide")
        applyWindowAppearance()
    }

    /// Sync AppKit's app-wide appearance with the chosen theme, so *every*
    /// window (including unfocused ones) repaints immediately on switch —
    /// `preferredColorScheme` alone leaves background windows stale until they
    /// next gain focus.
    private func applyWindowAppearance() {
        #if os(macOS)
        let appearance: NSAppearance? = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp?.appearance = appearance
        // SwiftUI manages each window's appearance from preferredColorScheme,
        // but only refreshes it when the window becomes key — set every window
        // directly so background windows repaint immediately too.
        for window in NSApp?.windows ?? [] {
            window.appearance = appearance
        }
        #endif
    }

    /// Text-contrast target: AAA when "increase contrast" is on, else AA.
    var contrastTarget: CGFloat { increaseContrast ? 7.0 : 4.5 }

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
        guard baseAccent != nil else { return nil }
        #if os(macOS)
        return Color(nsColor: adaptiveAccentNSColor)
        #else
        return baseAccent
        #endif
    }

    /// The current tint as a concrete colour, for previews/swatches.
    var resolvedAccent: Color { accentColor ?? .accentColor }

    /// The accent to use for *text* (links, a selected label), everywhere.
    ///
    /// On macOS this is the contrast-corrected `accentText`, which walks the
    /// accent until it clears the WCAG target against the window background.
    /// iOS has no equivalent machinery yet, so it takes the plain tint — the
    /// point of this property is that call sites don't platform-branch over a
    /// theming decision.
    var accentTextColor: Color {
        #if os(macOS)
        accentText ?? .accentColor
        #else
        resolvedAccent
        #endif
    }

    #if os(macOS)
    /// The chosen accent as an sRGB colour, deepened toward a richer mauve when
    /// "increase contrast" is on (so fills and labels have more headroom).
    private var solidBaseNSColor: NSColor? {
        guard let base = baseAccent else { return nil }
        let solid = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
        return increaseContrast ? (solid.blended(withFraction: 0.18, of: .black) ?? solid) : solid
    }

    /// The appearance-adaptive accent NSColor for control fills / decorations.
    var adaptiveAccentNSColor: NSColor {
        guard let solid = solidBaseNSColor else { return .controlAccentColor }
        return NSColor(name: nil) { appearance in
            Self.contextAdjusted(solid, isDark: Self.isDark(appearance))
        }
    }
    /// Alias kept for the editor call site.
    var editorAccentNSColor: NSColor { adaptiveAccentNSColor }

    /// The accent when used as *text* (links, selected labels): adjusted until it
    /// clears the current contrast target (AA 4.5 or, with increase-contrast on,
    /// AAA 7:1) against the window background — legible in either appearance.
    var accentTextNSColor: NSColor {
        guard let solid = solidBaseNSColor else { return .controlAccentColor }
        let target = contrastTarget
        return NSColor(name: nil) { appearance in
            let isDark = Self.isDark(appearance)
            let start = Self.contextAdjusted(solid, isDark: isDark)
            let bg: NSColor = isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.98, alpha: 1)
            return Self.readable(start, on: bg, towardDark: !isDark, target: target)
        }
    }

    /// The label colour to place *on top of* an accent fill (black or white,
    /// whichever contrasts better with the accent in the current appearance).
    var onAccentNSColor: NSColor {
        let solid = solidBaseNSColor
        return NSColor(name: nil) { appearance in
            let fill = solid.map { Self.contextAdjusted($0, isDark: Self.isDark(appearance)) } ?? .controlAccentColor
            return Self.contrast(.white, fill) >= Self.contrast(.black, fill) ? .white : .black
        }
    }

    /// The accent as a legible text colour, or `nil` for "multicolor".
    var accentText: Color? { baseAccent == nil ? nil : Color(nsColor: accentTextNSColor) }
    var onAccent: Color { Color(nsColor: onAccentNSColor) }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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
        #if os(macOS)
        // The Mac has no user-facing Dynamic Type, so the app's Text Size
        // slider drives the chrome directly.
        content
            .tint(settings.accentColor)
            .preferredColorScheme(settings.colorScheme)
            .dynamicTypeSize(settings.dynamicTypeSize)
        #else
        // On iOS the system Text Size (Dynamic Type) must win — forcing the
        // app's own size would override the user's accessibility setting. The
        // in-app slider still scales the editor and preview fonts.
        content
            .tint(settings.accentColor)
            .preferredColorScheme(settings.colorScheme)
        #endif
    }
}

extension View {
    /// Apply the app's appearance (accent tint, light/dark, text scale) at a
    /// window root.
    func themedRoot(_ settings: AppearanceSettings) -> some View {
        modifier(ThemedRoot(settings: settings))
    }
}

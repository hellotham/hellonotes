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
        case multicolor, blue, purple, pink, red, orange, yellow, green, graphite, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .multicolor: return "Multicolor"
            case .custom: return "Custom"
            default: return rawValue.capitalized
            }
        }

        /// The colour to tint with; `nil` for "multicolor" (follow the system
        /// accent) and for "custom" (the caller supplies the custom colour).
        var color: Color? {
            switch self {
            case .multicolor, .custom: return nil
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
        accent = Accent(rawValue: defaults.string(forKey: "accentChoice") ?? "") ?? .multicolor
        customAccent = Self.color(fromHex: defaults.string(forKey: "customAccentHex")) ?? .blue
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

    /// The tint colour to apply (`nil` = follow the system accent).
    var accentColor: Color? {
        accent == .custom ? customAccent : accent.color
    }

    /// The current tint as a concrete colour, for previews/swatches.
    var resolvedAccent: Color { accentColor ?? .accentColor }

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

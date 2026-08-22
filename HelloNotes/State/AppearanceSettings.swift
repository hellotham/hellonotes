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
import MarkdownEditor   // PlatformColor

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

    /// Show the note's filename above its body as an editable level-1 heading.
    /// On by default: without it a note appears to start mid-content.
    var showInlineTitle: Bool {
        didSet { UserDefaults.standard.set(showInlineTitle, forKey: "showInlineTitle") }
    }

    /// How notes are ordered inside each folder of the sidebar tree.
    ///
    /// It was a `@State` on `MacContentView` that nothing ever wrote and a
    /// hard-coded `.modified` on iOS: a `SortOrder` enum with `CaseIterable`, an
    /// `Identifiable` conformance and a `systemImage` per case, built for a
    /// picker that was never drawn on either platform. Here rather than on
    /// either shell so both read the same value, and so it follows the user
    /// across devices like every other view preference.
    var noteSortOrder: SortOrder {
        didSet { UserDefaults.standard.set(noteSortOrder.rawValue, forKey: "noteSortOrder") }
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
        // Full by default. The measure now applies to the *pane* rather than to
        // Preview alone, so a default of 80 characters would have narrowed the
        // live editor for everyone who never opened the setting — and "the pane
        // is the workspace" is the editor's documented default. Anyone who does
        // choose a measure now gets it in every mode, which is what choosing it
        // always looked like it meant.
        readingWidth = ReadingWidth(rawValue: defaults.string(forKey: "readingWidth") ?? "") ?? .full
        editorWidth = EditorWidth(rawValue: defaults.string(forKey: "editorWidth") ?? "") ?? .full
        wrapGuide = defaults.integer(forKey: "wrapGuide")
        noteSortOrder = SortOrder(rawValue: defaults.string(forKey: "noteSortOrder") ?? "") ?? .modified
        // Default on, so `bool(forKey:)` returning false for "never set" is
        // read as the default rather than as the user having turned it off.
        showInlineTitle = defaults.object(forKey: "showInlineTitle") as? Bool ?? true
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
        #else
        // Nothing to push. `preferredColorScheme` is applied per scene by
        // `.themedRoot(appearance)`, and `AppearanceSettings` is `@Observable`,
        // so every scene observing it repaints on its own. The Mac needs the
        // extra pass because the *window chrome* is AppKit's and SwiftUI only
        // refreshes it when a window becomes key — a background window would
        // otherwise stay in the old appearance until clicked.
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
        return Color(platform: adaptiveAccentPlatformColor)
    }

    /// The current tint as a concrete colour, for previews/swatches.
    var resolvedAccent: Color { accentColor ?? .accentColor }

    /// The accent to use for *text* (links, a selected label), everywhere.
    ///
    /// The contrast-corrected accent: walked toward black or white until it
    /// clears the WCAG target against the window background. It used to say
    /// "iOS has no equivalent machinery yet" and hand back the raw tint, which
    /// made "Increase contrast" inert on that platform — see
    /// `AccentContrast.swift` for why the machinery is no longer platform-shaped.
    var accentTextColor: Color { accentText ?? .accentColor }

    // MARK: - Accent, contrast-corrected
    //
    // Cross-platform. The arithmetic lives in `AccentContrast.swift`; what
    // remains here is which colour to ask for, and against what ground.

    /// The chosen accent as an sRGB triple, deepened when "increase contrast"
    /// is on (so fills and labels have more headroom).
    private var solidBase: SRGB? {
        guard let base = baseAccent else { return nil }
        let solid = PlatformColor(base).srgb
        return increaseContrast ? solid.blended(withFraction: 0.18, of: .black) : solid
    }

    /// The appearance-adaptive accent for control fills / decorations.
    var adaptiveAccentPlatformColor: PlatformColor {
        guard let solid = solidBase else { return .systemAccent }
        return .adaptive { isDark in solid.contextAdjusted(isDark: isDark) }
    }

    /// The accent the editor draws its selection, links and wrap guide in.
    ///
    /// Named for the job rather than for AppKit — it was `editorAccentNSColor`,
    /// and a name with a framework in it is a name only one platform can call.
    /// `EditorTheme` has taken a `PlatformColor?` since it was written; iOS was
    /// simply passing `nil` and getting `.tintColor`, so a chosen accent
    /// coloured the Mac's editor and not the iPad's.
    var editorAccentPlatformColor: PlatformColor { adaptiveAccentPlatformColor }

    /// The accent when used as *text* (links, selected labels): adjusted until
    /// it clears the current contrast target (AA 4.5 or, with increase-contrast
    /// on, AAA 7:1) against the window background — legible in either
    /// appearance.
    var accentTextPlatformColor: PlatformColor {
        guard let solid = solidBase else { return .systemAccent }
        let target = contrastTarget
        return .adaptive { isDark in
            solid.contextAdjusted(isDark: isDark)
                .readable(on: .windowGround(isDark: isDark),
                          towardDark: !isDark,
                          target: target)
        }
    }

    /// The label colour to place *on top of* an accent fill (black or white,
    /// whichever contrasts better with the accent in the current appearance).
    var onAccentPlatformColor: PlatformColor {
        let solid = solidBase
        return .adaptive { isDark in
            (solid?.contextAdjusted(isDark: isDark)
                ?? PlatformColor.systemAccent.srgb).labelOnTop
        }
    }

    /// The accent as a legible text colour, or `nil` for "multicolor".
    var accentText: Color? { baseAccent == nil ? nil : Color(platform: accentTextPlatformColor) }
    var onAccent: Color { Color(platform: onAccentPlatformColor) }

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

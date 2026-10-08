//
//  Chrome.swift
//  HelloNotes
//
//  Created by Chris Tham on 23/9/2026.
//
//  One look, drawn by the app, identical on both platforms — to the pixel.
//
//  The two platforms looked different because the app kept handing its chrome
//  to the OS: a system toolbar on each, an `NSOutlineView` sidebar on the Mac
//  and a SwiftUI `List` on iOS, text styles and system colours throughout. Each
//  of those is the platform's own drawing and resolves to the platform's own
//  numbers — `.body` is 13pt on macOS and 17pt on iOS, `.secondary` is a
//  different grey, a toolbar button is a different height — so two builds of
//  the same code could never be the same picture.
//
//  **Everything here is a fixed number**, and every number is the Mac's (the
//  chosen look): the colours were read from AppKit itself, in both
//  appearances, and the sizes from what the Mac's sidebar and toolbar drew.
//  App chrome uses these and nothing else — never a text style, never a
//  system colour, never `.bordered` or a `List` style, which would put the
//  platform back in charge of the drawing.
//
//  What stays the OS's: its own window chrome (traffic lights, status bar),
//  and a menu or popover once it is *open*. The buttons that open them are
//  ours and identical; the thing that drops down is drawn by the system.
//

import SwiftUI
import MarkdownEditor   // viewportSizeThatFits (S1)
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

enum Chrome {

    // MARK: - Type

    /// Explicit sizes, never text styles.
    enum Typeface {
        /// Note titles and the bar's emphasised text.
        static let title = Font.system(size: 13, weight: .semibold)
        /// Ordinary text in chrome — a search field, a tab.
        static let body = Font.system(size: 13)
        /// Folder, file and place rows.
        static let row = Font.system(size: 12)
        /// Subtitles, captions, counts.
        static let secondary = Font.system(size: 11)
        /// A collection's name heading its group.
        static let group = Font.system(size: 11, weight: .semibold)
        /// Glyphs inside rows.
        static let rowIcon = Font.system(size: 12)
        /// Glyphs on bar buttons.
        static let barIcon = Font.system(size: 14)
        /// A status bar's text and glyphs — the Mac's `.callout`, fixed.
        static let status = Font.system(size: 12)
    }

    // MARK: - Metrics

    enum Metric {
        /// The bar row: over the editor it holds the commands, over the sidebar
        /// and the panel it is the same height and empty or titled, so the three
        /// columns share one top edge.
        static let barHeight: CGFloat = 40
        /// A bar button, a tab, a segmented item.
        static let control: CGFloat = 28
        /// Where a finger lands. Invisible: the drawn control stays `control`,
        /// so a touch-only iPad draws the same pixels as a Mac and still gets
        /// Apple's minimum target.
        static let touchTarget: CGFloat = 44
        static let barPadding: CGFloat = 10
        static let barSpacing: CGFloat = 4
        static let radius: CGFloat = 6
        /// Sidebar rows — `SidebarRowHeights`, which are the Mac's.
        static let rowNote: CGFloat = SidebarRowHeights.note
        static let rowCollection: CGFloat = SidebarRowHeights.collection
        static let rowLeaf: CGFloat = SidebarRowHeights.leaf
        static let indent: CGFloat = 14
        /// How far a selection's rounded rectangle sits inside its row.
        static let selectionInsetX: CGFloat = 5
        static let selectionInsetY: CGFloat = 1
        static let searchWidth: CGFloat = 180
        static let tabMaxWidth: CGFloat = 200
        /// A status bar's row, inside its 5pt vertical padding.
        static let statusRow: CGFloat = 34
    }

    // MARK: - Colour

    /// AppKit's values, fixed per appearance. On iOS these replace the UIKit
    /// system colours, which are different numbers under the same names.
    enum Colour {
        static let label = Color.chrome(light: (0, 0, 0, 0.847), dark: (255, 255, 255, 0.847))
        static let secondaryLabel = Color.chrome(light: (0, 0, 0, 0.498), dark: (255, 255, 255, 0.549))
        static let tertiaryLabel = Color.chrome(light: (0, 0, 0, 0.259), dark: (255, 255, 255, 0.247))
        static let separator = Color.chrome(light: (0, 0, 0, 0.098), dark: (255, 255, 255, 0.098))
        /// The editor and the window.
        static let content = Color.chrome(light: (255, 255, 255, 1), dark: (30, 30, 30, 1))
        /// The sidebar, the bar row and the panel — AppKit's under-page grey.
        static let chrome = Color.chrome(light: (246, 246, 246, 1), dark: (40, 40, 40, 1))
        /// A control at rest: search field, tab.
        static let fill = Color.chrome(light: (0, 0, 0, 0.047), dark: (255, 255, 255, 0.047))
        /// A control under the pointer.
        static let hover = Color.chrome(light: (0, 0, 0, 0.027), dark: (255, 255, 255, 0.027))
        static let quaternaryLabel = Color.chrome(light: (0, 0, 0, 0.098), dark: (255, 255, 255, 0.098))

        // A grouped form, read off the Mac's own (`formStyle(.grouped)`,
        // rendered and scanned): the section's box, and the rule between rows.
        static let groupFill = Color.chrome(light: (0, 0, 0, 0.031), dark: (255, 255, 255, 0.031))
        static let groupSeparator = Color.chrome(light: (0, 0, 0, 0.05), dark: (255, 255, 255, 0.048))
        /// A push button's face, a pop-up's chevron disc, a stepper.
        static let controlFill = Color.chrome(light: (0, 0, 0, 0.077), dark: (255, 255, 255, 0.10))
        static let controlFillPressed = Color.chrome(light: (0, 0, 0, 0.14), dark: (255, 255, 255, 0.17))
        /// A switch or slider track that is off.
        static let trackOff = Color.chrome(light: (0, 0, 0, 0.12), dark: (255, 255, 255, 0.16))
        /// A text field's rim.
        static let fieldBorder = Color.chrome(light: (0, 0, 0, 0.12), dark: (255, 255, 255, 0.14))

        // The system hues, as AppKit resolves them (macOS 27, both
        // appearances). `Color.orange` is a different orange on iOS.
        static let red = Color.chrome(light: (255, 56, 60, 1), dark: (255, 66, 69, 1))
        static let orange = Color.chrome(light: (255, 141, 40, 1), dark: (255, 146, 48, 1))
        static let yellow = Color.chrome(light: (255, 204, 0, 1), dark: (255, 214, 0, 1))
        static let green = Color.chrome(light: (52, 199, 89, 1), dark: (48, 209, 88, 1))
        static let blue = Color.chrome(light: (0, 136, 255, 1), dark: (0, 145, 255, 1))
        static let purple = Color.chrome(light: (203, 48, 224, 1), dark: (219, 52, 242, 1))
        static let pink = Color.chrome(light: (255, 45, 85, 1), dark: (255, 55, 95, 1))
        static let teal = Color.chrome(light: (0, 195, 208, 1), dark: (0, 210, 224, 1))
        static let gray = Color.chrome(light: (142, 142, 147, 1), dark: (152, 152, 157, 1))
        static let indigo = Color.chrome(light: (97, 85, 245, 1), dark: (109, 124, 255, 1))
        static let cyan = Color.chrome(light: (0, 192, 232, 1), dark: (60, 211, 254, 1))
        static let mint = Color.chrome(light: (0, 200, 179, 1), dark: (0, 218, 195, 1))
        static let brown = Color.chrome(light: (172, 127, 94, 1), dark: (183, 138, 102, 1))
    }

    /// A selected row's fill: the accent at 30%, as the Mac's `AccentRowView`
    /// drew it. Never the accent at full strength with an accent glyph inside
    /// — accent on accent draws nothing.
    static func selection(_ accent: Color) -> Color { accent.opacity(0.30) }

    /// Rasterize text the way iOS does. **Called once, before anything draws.**
    ///
    /// With every size and colour fixed, the chrome rendered at identical
    /// dimensions on both platforms and the text in identical places — the
    /// centre of the ink agreed within 0.18px — but the Mac's text carried
    /// 12.6–19% more ink (`ChromeParityTests`, measured). That is macOS font
    /// smoothing, which thickens glyph stems and which iOS has never done.
    /// Registered, not written: the registration domain is in memory and
    /// last in the search order, so nothing reaches disk, and a Mac on which
    /// someone has set `AppleFontSmoothing` system-wide keeps their choice.
    static func matchTextRendering() {
        #if os(macOS)
        UserDefaults.standard.register(defaults: ["AppleFontSmoothing": 0])
        #else
        // iOS has no font smoothing to switch off.
        #endif
    }
}

extension Color {
    /// A colour with fixed components per appearance, the **same numbers on
    /// both platforms**. A system colour resolves to each platform's own value;
    /// this resolves to these, on either. Components are 0–255 for RGB and 0–1
    /// for alpha, in sRGB.
    static func chrome(light: (Double, Double, Double, Double),
                       dark: (Double, Double, Double, Double)) -> Color {
        #if canImport(AppKit)
        let light = NSColor(srgbRed: light.0 / 255, green: light.1 / 255, blue: light.2 / 255, alpha: light.3)
        let dark = NSColor(srgbRed: dark.0 / 255, green: dark.1 / 255, blue: dark.2 / 255, alpha: dark.3)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
        #else
        let light = UIColor(red: light.0 / 255, green: light.1 / 255, blue: light.2 / 255, alpha: light.3)
        let dark = UIColor(red: dark.0 / 255, green: dark.1 / 255, blue: dark.2 / 255, alpha: dark.3)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
        #endif
    }
}

// MARK: - The OS's own window chrome

/// Room for the OS's window controls at a window's top-left — the Mac's
/// traffic lights. **The one number in the chrome that is not the same on both
/// platforms**, because what it makes room for is the OS's, not the app's.
/// Used only where the app's bar reaches that corner: when the sidebar is put
/// away and the bar is the top-left of the window.
enum WindowControls {
    static var leadingInset: CGFloat {
        #if os(macOS)
        return 78
        #else
        return 0
        #endif
    }
}

extension View {
    /// Drag the window by this view — where the OS's title bar would have been
    /// if the app did not draw its own. Applied to a bar's *background*, so
    /// the buttons on it still take their clicks.
    func windowDraggable() -> some View {
        #if os(macOS)
        return gesture(WindowDragGesture())
        #else
        return self
        #endif
    }
}

extension View {
    /// The window's top edge is the app's bar, on the Mac too.
    ///
    /// With the title bar hidden, SwiftUI still keeps its height as a top
    /// safe area, so the bar sat 28pt below the top of the window with an empty
    /// strip above it — the Mac window and the iPad's differed by exactly that
    /// (`scripts/window-parity.sh`). Ignoring it puts the bar row at the top and
    /// the traffic lights over the sidebar's header, which is what D11 says.
    /// iOS keeps its safe area: the status bar above it is the OS's.
    func contentUnderTitleBar() -> some View {
        #if os(macOS)
        return ignoresSafeArea(.container, edges: .top)
        #else
        return self
        #endif
    }
}

extension View {
    /// **For the whole-window parity capture only:** size this window's content
    /// to `-HNWindowWidth` × `-HNWindowHeight` — the iPad's safe area — once,
    /// when it appears. A scene's `defaultSize` loses to any frame AppKit has
    /// saved for the window, and the launch came up 1153×721, 1210×790 and
    /// 1090×712 on three runs asking for the same size. Nothing happens
    /// without the arguments. iOS: the system sizes the scene.
    func capturedWindowSize() -> some View {
        #if os(macOS)
        return background(CaptureWindowSizer())
        #else
        return self
        #endif
    }
}

#if os(macOS)
private struct CaptureWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SizerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    /// A viewport, like every representable here: the size it is offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? { viewportSizeThatFits(proposal) }

    final class SizerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let defaults = UserDefaults.standard
            let width = defaults.double(forKey: "HNWindowWidth")
            let height = defaults.double(forKey: "HNWindowHeight")
            guard width > 0, height > 0, let window else { return }
            DispatchQueue.main.async {
                window.setContentSize(NSSize(width: width, height: height))
            }
        }
    }
}
#else
// iOS: the system sizes a scene, and the capture's iPad half is the device.
#endif

extension Scene {
    /// The Mac's title bar, hidden: the app's own 40pt bar row is the top of
    /// the window on both platforms, instead of a 28pt system strip above it
    /// on the Mac alone. The traffic lights sit in the sidebar header's empty
    /// leading end.
    func appDrawnTitleBar() -> some Scene {
        #if os(macOS)
        return windowStyle(.hiddenTitleBar)
        #else
        return self
        #endif
    }
}

// MARK: - Text

/// One line of chrome text — **placed by its capitals, in a line box the app
/// chooses**, so it lands on the same pixels on both platforms.
///
/// A `Text` sits in a line box the platform derives from the font, and the two
/// platforms derive it differently: macOS rounds a line to whole points (11pt
/// → 14.0, 12pt → 15.0, 17pt → 20.0) and iOS to half points (13.5, 14.5,
/// 20.5), and even where the totals agree (13pt → 16.0 on both) macOS rounds
/// the ascent and descent separately, putting the baseline half a point
/// lower. Centring that box in a control therefore moved every single line of
/// chrome text one pixel down on the Mac (`ChromeParityTests`, measured: the
/// ink identical, its centre +1.000px on y). The capitals are the font's own
/// outline — the same on both — so this centres *them*, measured from the
/// baseline, and gives the line a box of a fixed height that nothing about the
/// platform can change.
struct ChromeLine: View {
    let text: String
    var size: CGFloat
    var weight: Font.Weight = .regular
    var colour: Color = Chrome.Colour.label
    /// Digits of one width, for a date or a count that should not jitter.
    var monospacedDigits = false
    /// SF's capital height as a share of its size (1443/2048).
    private static let capRatio: CGFloat = 0.7046

    init(_ text: String, size: CGFloat, weight: Font.Weight = .regular,
         colour: Color = Chrome.Colour.label, monospacedDigits: Bool = false) {
        self.text = text
        // Whole points: a scaled size (a row at 110%) would otherwise give the
        // text a fractional line, which each platform rounds its own way.
        self.size = size.rounded()
        self.weight = weight
        self.colour = colour
        self.monospacedDigits = monospacedDigits
    }

    private var font: Font {
        let font = Font.system(size: size, weight: weight)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(colour)
            .lineLimit(1)
            .truncationMode(.tail)
            .alignmentGuide(VerticalAlignment.center) { d in
                d[.firstTextBaseline] - size * Self.capRatio / 2
            }
            .frame(height: Chrome.lineBox(size))
    }
}

extension Chrome {
    /// The line box for a size: the Mac's own value (11pt → 14, 12 → 15,
    /// 13 → 16, 14 → 17, 17 → 20 — `ChromeParityTests.lineHeights`), now
    /// fixed on both, so the Mac's layout is unchanged and the iPad takes it.
    static func lineBox(_ size: CGFloat) -> CGFloat { (size + 3).rounded() }
}

// MARK: - Controls

/// A bar button: a 14pt glyph in a 28pt square that fills on hover and when
/// on, with a 44pt hit area around it for fingers. The same pixels on both
/// platforms because nothing here is a system button style.
struct ChromeButton: View {
    let title: String
    let systemImage: String
    var isOn: Bool = false
    var accent: Color = .accentColor
    /// What VoiceOver says, when that should be more than the tooltip.
    var spokenName: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChromeGlyph(systemImage: systemImage, isOn: isOn, hovering: hovering, accent: accent)
        }
        .buttonStyle(ChromePlainStyle())
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(spokenName ?? title)
    }
}

/// A bar button that opens a menu. The button is ours and identical; the menu
/// that drops from it is drawn by the OS.
struct ChromeMenuButton<Content: View>: View {
    let title: String
    let systemImage: String
    var accent: Color = .accentColor
    /// What VoiceOver says, when that should be more than the tooltip.
    var spokenName: String? = nil
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            // A `Label` rather than a bare glyph, so the menu has a name
            // wherever the system reads one; drawn as the glyph alone.
            Label {
                Text(title)
            } icon: {
                ChromeGlyph(systemImage: systemImage, isOn: false, hovering: hovering, accent: accent)
            }
            .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(ChromePlainStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(spokenName ?? title)
    }
}

/// The drawn part of a bar button.
struct ChromeGlyph: View {
    let systemImage: String
    var isOn: Bool
    var hovering: Bool
    var accent: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(Chrome.Typeface.barIcon)
            .foregroundStyle(isOn ? accent : Chrome.Colour.secondaryLabel)
            .frame(width: Chrome.Metric.control, height: Chrome.Metric.control)
            .background(
                RoundedRectangle(cornerRadius: Chrome.Metric.radius)
                    .fill(isOn ? Chrome.selection(accent)
                               : hovering ? Chrome.Colour.hover : Color.clear))
            // The finger's target, not the drawing's.
            .contentShape(.rect.inset(by: -(Chrome.Metric.touchTarget - Chrome.Metric.control) / 2))
    }
}

/// No platform styling at all: the label is drawn exactly as given — dimmed
/// when pressed or disabled, by the same amounts on both platforms. `.plain`
/// is close, but still tints and dims per OS; and a plain style that ignores
/// `isEnabled` draws a disabled button exactly like an enabled one.
struct ChromePlainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.6 : 1)
        }
    }
}

// MARK: - Status bars

/// A thin rule between groups in a status bar.
struct ChromeStatusSeparator: View {
    var body: some View {
        Rectangle().fill(Chrome.Colour.separator).frame(width: 1, height: 11)
    }
}

/// A glyph button in a status bar: 12pt in a 22×18 frame, the secondary label
/// colour, and a larger target around it for a finger.
struct ChromeStatusButton: View {
    let help: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Chrome.Typeface.status)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .frame(width: 22, height: 18)
                .contentShape(.rect.inset(by: -12))
        }
        .buttonStyle(ChromePlainStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A glyph in a status bar that opens a menu. The glyph is ours; the menu is
/// the OS's.
struct ChromeStatusMenu<Content: View>: View {
    let help: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Label {
                Text(help)
            } icon: {
                Image(systemName: systemImage)
                    .font(Chrome.Typeface.status)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .frame(width: 22, height: 18)
                    .contentShape(.rect.inset(by: -12))
            }
            .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(ChromePlainStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A segmented control drawn by the app. The system's is an `NSSegmentedControl`
/// on the Mac and a `UISegmentedControl` on iOS — different heights, radii,
/// fills and selection — so a mode switch looked like two different controls.
///
/// Two sizes: glyphs only (30×20 segments, the status bar's mode switch), or
/// `showsTitles` — the Mac's regular segmented control, 24pt tall with 13pt
/// titles, for a choice in a form.
struct ChromeSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let systemImage: String
        let label: String

        init(value: Value, systemImage: String = "", label: String) {
            self.value = value
            self.systemImage = systemImage
            self.label = label
        }
    }

    @Binding var selection: Value
    let options: [Option]
    var showsTitles = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    segment(option, isOn: isOn)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Chrome.Colour.content)
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(Chrome.Colour.separator, lineWidth: 0.5))
                            }
                        }
                        .contentShape(.rect.inset(by: -10))
                }
                .buttonStyle(ChromePlainStyle())
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Chrome.Colour.fill, in: RoundedRectangle(cornerRadius: Chrome.Metric.radius))
    }

    @ViewBuilder
    private func segment(_ option: Option, isOn: Bool) -> some View {
        let colour = isOn ? Chrome.Colour.label : Chrome.Colour.secondaryLabel
        if showsTitles {
            HStack(spacing: 5) {
                if !option.systemImage.isEmpty {
                    Image(systemName: option.systemImage).font(Chrome.Style.sized(12))
                }
                Text(option.label).font(Chrome.Style.body).lineLimit(1)
            }
            .foregroundStyle(colour)
            .padding(.horizontal, 10)
            .frame(minWidth: 56, minHeight: 20, maxHeight: 20)
        } else {
            Image(systemName: option.systemImage)
                .font(Chrome.Typeface.status)
                .foregroundStyle(colour)
                .frame(width: 30, height: 20)
        }
    }
}

//
//  ChromeControls.swift
//  HelloNotes
//
//  Created by Chris Tham on 23/9/2026.
//
//  The controls and containers everything else is built from — text at fixed
//  sizes, buttons, switches, pop-ups, sliders, steppers, fields, spinners,
//  forms, sheets, empty states — **drawn by the app**, so each is the same
//  picture on both platforms.
//
//  Each of these replaces a system one that is two different drawings under
//  one name. `Toggle` is an `NSSwitch` 36pt wide on the Mac and a
//  `UISwitch` 51pt wide on iOS; a `Form` is 13pt rows 36pt tall on the Mac and
//  17pt rows 44pt tall on iOS; `.borderless` draws its label grey on the Mac
//  and in the accent on iOS; `.font(.body)` is 13pt and 17pt. The numbers
//  here are the Mac's — the chosen look — read off the controls themselves
//  (`NSControl.fittingSize` per control size, and a `.grouped` `Form`
//  rendered and scanned pixel by pixel), and they are the same on iOS by
//  construction because nothing here asks the platform how to draw.
//
//  Where SwiftUI has a public style protocol (buttons, toggles, progress,
//  disclosure groups, labelled content, labels), the style is applied once at
//  every window's root (`chromeDefaults`), so an unstyled control is already
//  ours. Where it has none (pickers, sliders, steppers, forms), there is a
//  view here to use instead.
//
//  What stays the OS's: a menu once it is open, a text field's caret and
//  selection, the colour panel, an alert — transient things the OS presents,
//  like the menus the bar's buttons open.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Type

/// The text-size controls, as one multiplier on every chrome size.
///
/// Chrome text used to be text styles, and each platform scaled them by its
/// own control: the Mac by the app's Text Size slider (`dynamicTypeSize`, set
/// in `ThemedRoot`), iOS by the system's Text Size alone — so with the slider
/// moved (and it syncs between devices) the same chrome was a different size
/// on each. The sizes are the Mac's now, and **both platforms scale them by the
/// app's Text Size**, through one table; iOS then also applies the system's
/// Larger Text, which the Mac has no equivalent of. At the defaults every
/// factor is exactly 1, which is where the pixels are compared.
@Observable
final class ChromeTextScale {
    static let shared = ChromeTextScale()
    private(set) var factor: CGFloat = 1

    /// The app's Text Size, and — on iOS — the system's.
    func update(app: DynamicTypeSize, system: DynamicTypeSize = .large) {
        let next = Self.factor(for: app) * Self.factor(for: system)
        if next != factor { factor = next }
    }

    /// Apple's own ratios for body text at each size, relative to `.large`.
    static func factor(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 14.0 / 17
        case .small: return 15.0 / 17
        case .medium: return 16.0 / 17
        case .large: return 1
        case .xLarge: return 19.0 / 17
        case .xxLarge: return 21.0 / 17
        case .xxxLarge: return 23.0 / 17
        case .accessibility1: return 28.0 / 17
        case .accessibility2: return 33.0 / 17
        case .accessibility3: return 40.0 / 17
        case .accessibility4: return 47.0 / 17
        case .accessibility5: return 53.0 / 17
        @unknown default: return 1
        }
    }
}

extension Chrome {
    /// The Mac's text styles as sizes (`NSFont.preferredFont(forTextStyle:)`,
    /// macOS 27), for text that used a text style. On iOS the same names are
    /// 17pt body, 15pt subheadline, 12pt caption — every one different.
    enum Style {
        static var largeTitle: Font { sized(26) }
        static var title: Font { sized(22) }
        static var title2: Font { sized(17) }
        static var title3: Font { sized(15) }
        static var headline: Font { sized(13, .bold) }
        static var subheadline: Font { sized(11) }
        static var body: Font { sized(13) }
        static var callout: Font { sized(12) }
        static var footnote: Font { sized(10) }
        static var caption: Font { sized(10) }
        static var caption2: Font { sized(10) }

        /// A size of the Mac's, at the current text size, in whole points.
        static func sized(_ size: CGFloat, _ weight: Font.Weight = .regular,
                          design: Font.Design = .default) -> Font {
            .system(size: points(size), weight: weight, design: design)
        }

        static func points(_ size: CGFloat) -> CGFloat {
            (size * ChromeTextScale.shared.factor).rounded()
        }
    }

    /// **Every line of text is its point size plus 3, in whole points, on
    /// both platforms.** Left to themselves the two round a line box
    /// differently — the Mac to whole points, iOS to half points: 11pt is
    /// 14.0 and 13.5, 17pt 20.0 and 20.5 — so a paragraph drifted half a point
    /// a line and anything centred against it moved a pixel.
    ///
    /// A rule only fixes that if its result is already whole. The first one
    /// here was `.multiple(factor: 16/13)` — a multiple of the point size — and
    /// it agreed at 11, 13, 17 and 26pt, where 16/13 happens to land on whole
    /// points, and nowhere else (10pt: 13.0 against 12.5; 15pt, 19.0 against
    /// 18.5), because each platform then rounded the fraction its own way.
    /// `.leading(increase:)` adds to the point size, so with a whole size and
    /// a whole increase there is nothing to round (`ChromeParityTests`,
    /// measured on both). Plus 3 is the Mac's own line at 10–13pt and at 17 —
    /// 13, 14, 15, 16 and 20 — so the Mac barely moves; it is the same number
    /// `ChromeLine` gives a single line's box.
    static let lineHeight = AttributedString.LineHeight.leading(increase: 3)
}

// MARK: - Buttons

/// A label drawn as given, dimmed when pressed or disabled. The base of the
/// other styles; `ChromePlainStyle` is this with nothing added.
private struct DimmedLabel<Label: View>: View {
    var isPressed: Bool
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label.opacity(!isEnabled ? 0.35 : isPressed ? 0.6 : 1)
    }
}

/// The Mac's `.borderless`: the label in the secondary colour, no bezel.
/// (iOS draws `.borderless` in the accent, as a link.)
struct ChromeBorderlessStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DimmedLabel(isPressed: configuration.isPressed) {
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? Chrome.Colour.red
                                                                   : Chrome.Colour.secondaryLabel)
                .contentShape(.rect)
        }
    }
}

/// Text that is a link: the accent, no bezel.
struct ChromeLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DimmedLabel(isPressed: configuration.isPressed) {
            configuration.label
                .foregroundStyle(.tint)
                .contentShape(.rect)
        }
    }
}

/// A push button — the Mac's: 24pt tall at the regular size, 13pt text,
/// a 6pt radius, the face a 7.7% wash; prominent is the accent with white
/// text. Sizes follow `controlSize` exactly as `NSButton` does (16/20/24/28).
struct ChromePushStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, prominent: prominent)
    }

    struct Metrics {
        let height: CGFloat, font: CGFloat, padding: CGFloat, radius: CGFloat
        init(_ size: ControlSize) {
            switch size {
            case .mini: (height, font, padding, radius) = (16, 9, 6, 4)
            case .small: (height, font, padding, radius) = (20, 11, 9, 5)
            case .large, .extraLarge: (height, font, padding, radius) = (28, 13, 14, 7)
            default: (height, font, padding, radius) = (24, 13, 12, 6)
            }
        }
    }

    private struct Face: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let m = Metrics(controlSize)
            let destructive = configuration.role == .destructive
            configuration.label
                .font(.system(size: m.font))
                .lineLimit(1)
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white)
                                 : destructive ? AnyShapeStyle(Chrome.Colour.red)
                                 : AnyShapeStyle(Chrome.Colour.label))
                .padding(.horizontal, m.padding)
                .frame(minHeight: m.height, maxHeight: m.height)
                .background {
                    RoundedRectangle(cornerRadius: m.radius)
                        .fill(prominent ? AnyShapeStyle(.tint)
                              : configuration.isPressed ? AnyShapeStyle(Chrome.Colour.controlFillPressed)
                              : AnyShapeStyle(Chrome.Colour.controlFill))
                        .overlay {
                            if prominent && configuration.isPressed {
                                RoundedRectangle(cornerRadius: m.radius).fill(Color.black.opacity(0.15))
                            }
                        }
                }
                .contentShape(.rect)
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

// MARK: - Toggles

/// The Mac's switch — a 36×16 track, a white 20×12 knob — with the label to
/// its left and room between, as a form row draws it. `labelsHidden()`
/// leaves the switch alone.
struct ChromeSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: Configuration
        @Environment(\.labelsVisibility) private var labelsVisibility
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: 8) {
                if labelsVisibility != .hidden {
                    configuration.label
                    Spacer(minLength: 8)
                }
                track
            }
            .chromeToggleAccessibility(configuration)
        }

        private var track: some View {
            let on = configuration.isOn
            return Capsule()
                .fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.Colour.trackOff))
                .frame(width: 36, height: 16)
                .overlay(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 20, height: 12)
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                        .padding(2)
                }
                .opacity(isEnabled ? 1 : 0.4)
                // The finger's target, not the drawing's.
                .contentShape(.rect.inset(by: -12))
                .onTapGesture {
                    guard isEnabled else { return }
                    withAnimation(.snappy(duration: 0.18)) { configuration.isOn.toggle() }
                }
        }
    }
}

/// The Mac's checkbox: a 14pt rounded square, the accent with a white tick
/// when on, the label to its right.
struct ChromeCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CheckboxBody(configuration: configuration)
    }

    private struct CheckboxBody: View {
        let configuration: Configuration
        @Environment(\.labelsVisibility) private var labelsVisibility
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let on = configuration.isOn
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.Colour.content))
                    .overlay {
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.white)
                        } else {
                            RoundedRectangle(cornerRadius: 3.5)
                                .strokeBorder(Chrome.Colour.fieldBorder, lineWidth: 1)
                        }
                    }
                    .frame(width: 14, height: 14)
                if labelsVisibility != .hidden {
                    configuration.label
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect.inset(by: -8))
            .onTapGesture {
                guard isEnabled else { return }
                configuration.isOn.toggle()
            }
            .chromeToggleAccessibility(configuration)
        }
    }
}

private extension View {
    /// What VoiceOver reads for a drawn toggle: one element, a toggle, its
    /// state, and an action that flips it. (An `accessibilityRepresentation`
    /// holding a `Toggle` would resolve this same style again.)
    func chromeToggleAccessibility(_ configuration: ToggleStyleConfiguration) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// A toggle drawn as a push button that stays down while on.
struct ChromeToggleButtonStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Chrome.Colour.label))
        }
        .buttonStyle(ChromePushStyle())
        .overlay {
            if configuration.isOn {
                RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.18)).allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

// MARK: - Choosing one of several

/// One choice in a `ChromePopUp` or `ChromeSegmented`.
struct ChromeOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String? = nil
    var id: Value { value }
}

/// A pop-up button — a `Picker` of the `.menu` kind — with the face drawn by
/// the app: the value in 13pt and the Mac's chevron disc beside it. The menu
/// it opens is the OS's, with the OS's tick against the value.
///
/// A `Picker` cannot be restyled (`PickerStyle` has no public requirements),
/// and its face is the platform's: a bezelled pop-up on the Mac, tinted text
/// on iOS. So this takes its choices as data, which also gives it the title
/// of the chosen one to draw.
struct ChromePopUp<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ChromeOption<Value>]

    @Environment(\.labelsVisibility) private var labelsVisibility
    @State private var hovering = false

    init(_ title: String, selection: Binding<Value>, options: [ChromeOption<Value>]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    private var current: ChromeOption<Value>? { options.first { $0.value == selection } }

    var body: some View {
        HStack(spacing: 8) {
            if labelsVisibility != .hidden {
                Text(title)
                Spacer(minLength: 8)
            }
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options) { option in
                        if let image = option.systemImage {
                            Label(option.title, systemImage: image).tag(option.value)
                        } else {
                            Text(option.title).tag(option.value)
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label {
                    Text(title)
                } icon: {
                    face
                }
                .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(ChromePlainStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(current?.title ?? "")
        }
    }

    private var face: some View {
        HStack(spacing: 6) {
            if let image = current?.systemImage {
                Image(systemName: image)
                    .font(Chrome.Style.sized(12))
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
            Text(current?.title ?? "—")
                .font(Chrome.Style.body)
                .foregroundStyle(Chrome.Colour.label)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Chrome.Colour.label)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Chrome.Colour.controlFillPressed
                                                   : Chrome.Colour.controlFill))
        }
        .frame(height: 24)
        .contentShape(.rect.inset(by: -10))
        .onHover { hovering = $0 }
    }
}

/// A pull-down: a menu of commands behind a titled push button.
struct ChromePullDown<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder let content: () -> Content

    init(_ title: String, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            Label {
                Text(title)
            } icon: {
                HStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: systemImage).font(Chrome.Style.sized(12))
                    }
                    Text(title).font(Chrome.Style.body).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Chrome.Colour.label)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Chrome.Colour.controlFill))
                .contentShape(.rect.inset(by: -10))
            }
            .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(ChromePlainStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

// MARK: - Continuous values

/// The Mac's slider: a 6pt track filled with the accent to the value, and a
/// white 20×16 knob. `Slider` has no style to restyle, and its two drawings
/// share nothing — a thin line with a round knob on iOS.
struct ChromeSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragging = false

    private static let knob = CGSize(width: 20, height: 16)

    init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, step: Double? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(width - Self.knob.width, 1)
            let x = Self.knob.width / 2 + fraction * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Chrome.Colour.trackOff).frame(height: 6)
                Capsule().fill(.tint).frame(width: x, height: 6)
                Capsule()
                    .fill(Color.white)
                    .frame(width: Self.knob.width, height: Self.knob.height)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                    .offset(x: x - Self.knob.width / 2)
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(.rect.inset(by: -10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let f = min(max((gesture.location.x - Self.knob.width / 2) / travel, 0), 1)
                        set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in
                        if dragging { dragging = false; onEditingChanged(false) }
                    })
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            let unit = step ?? (range.upperBound - range.lowerBound) / 10
            switch direction {
            case .increment: set(value + unit)
            case .decrement: set(value - unit)
            @unknown default: break
            }
        }
    }

    private func set(_ raw: Double) {
        var next = min(max(raw, range.lowerBound), range.upperBound)
        if let step, step > 0 {
            next = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step
        }
        if next != value { value = next }
    }
}

/// The Mac's stepper: two halves of a 20×24 rounded box, the label to its
/// left.
struct ChromeStepper<Label: View>: View {
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    var canIncrement = true
    var canDecrement = true
    @ViewBuilder let label: () -> Label

    @Environment(\.labelsVisibility) private var labelsVisibility

    init(onIncrement: @escaping () -> Void, onDecrement: @escaping () -> Void,
         canIncrement: Bool = true, canDecrement: Bool = true,
         @ViewBuilder label: @escaping () -> Label) {
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
        self.canIncrement = canIncrement
        self.canDecrement = canDecrement
        self.label = label
    }

    var body: some View {
        HStack(spacing: 8) {
            if labelsVisibility != .hidden {
                label()
                Spacer(minLength: 8)
            }
            VStack(spacing: 0) {
                half("chevron.up", enabled: canIncrement, action: onIncrement)
                Rectangle().fill(Chrome.Colour.groupSeparator).frame(height: 1)
                half("chevron.down", enabled: canDecrement, action: onDecrement)
            }
            .frame(width: 20, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Chrome.Colour.controlFill))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrement { onIncrement() }
            case .decrement: if canDecrement { onDecrement() }
            @unknown default: break
            }
        }
    }

    private func half(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Chrome.Colour.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(ChromePlainStyle())
        .disabled(!enabled)
    }
}

extension ChromeStepper {
    /// A stepper over a whole number in a range.
    init(value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1,
         @ViewBuilder label: @escaping () -> Label) {
        self.init(onIncrement: { value.wrappedValue = min(value.wrappedValue + step, range.upperBound) },
                  onDecrement: { value.wrappedValue = max(value.wrappedValue - step, range.lowerBound) },
                  canIncrement: value.wrappedValue < range.upperBound,
                  canDecrement: value.wrappedValue > range.lowerBound,
                  label: label)
    }

    /// A stepper over a decimal in a range.
    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
         @ViewBuilder label: @escaping () -> Label) {
        self.init(onIncrement: { value.wrappedValue = min(value.wrappedValue + step, range.upperBound) },
                  onDecrement: { value.wrappedValue = max(value.wrappedValue - step, range.lowerBound) },
                  canIncrement: value.wrappedValue < range.upperBound,
                  canDecrement: value.wrappedValue > range.lowerBound,
                  label: label)
    }
}

// MARK: - Text entry

/// A text field in a box — a 24pt field, 13pt text, a 6pt radius and a
/// hairline rim — with **its placeholder drawn by the app**. The field underneath is `.plain`, which draws no
/// chrome of its own; a system placeholder is a different grey on each
/// platform, and on iOS it is where a title goes to disappear
/// (`LabeledField`).
struct ChromeTextField: View {
    /// What the field is — read by VoiceOver, never drawn.
    let title: String
    @Binding var text: String
    var prompt: String? = nil
    var axis: Axis = .horizontal
    var isSecure = false

    init(_ title: String, text: Binding<String>, prompt: String? = nil,
         axis: Axis = .horizontal, isSecure: Bool = false) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.axis = axis
        self.isSecure = isSecure
    }

    var body: some View {
        ZStack(alignment: axis == .vertical ? .topLeading : .leading) {
            if text.isEmpty, let prompt {
                Text(prompt)
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
                    .lineLimit(axis == .vertical ? nil : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            field
                .textFieldStyle(.plain)
                .foregroundStyle(Chrome.Colour.label)
                .focusEffectDisabled()
                .accessibilityLabel(title)
        }
        .font(Chrome.Style.body)
        .chromeFieldBox(multiline: axis == .vertical)
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField("", text: $text)
        } else {
            TextField("", text: $text, axis: axis)
        }
    }
}

extension View {
    /// The box a `ChromeTextField` draws, for a field that is not one: a
    /// `TextEditor`, or a `TextField` whose call site needs to keep its own
    /// `.focused`/`.onSubmit` on the field itself.
    func chromeFieldBox(multiline: Bool = false) -> some View {
        padding(.horizontal, 7)
            .padding(.vertical, multiline ? 5 : 0)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Chrome.Colour.content))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.Colour.fieldBorder, lineWidth: 1))
    }

    /// Draw `prompt` behind this field while `text` is empty — the app's
    /// placeholder, for a `TextField("", text:)` that keeps its own modifiers.
    /// Pair with `.textFieldStyle(.plain)` and an `accessibilityLabel`.
    func chromePlaceholder(_ prompt: String, showing isEmpty: Bool,
                           alignment: Alignment = .leading) -> some View {
        background(alignment: alignment) {
            if isEmpty {
                Text(prompt)
                    .foregroundStyle(Chrome.Colour.tertiaryLabel)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A search field: the glyph, an app-drawn prompt and a clear button in a
/// 28pt well — the bar's own field, for anywhere else that searches.
struct ChromeSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var onSubmit: () -> Void = {}

    init(text: Binding<String>, prompt: String = "Search", onSubmit: @escaping () -> Void = {}) {
        self._text = text
        self.prompt = prompt
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(Chrome.Typeface.rowIcon)
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt)
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Chrome.Colour.label)
                    .focusEffectDisabled()
                    .onSubmit(onSubmit)
                    .accessibilityLabel(prompt)
            }
            .font(Chrome.Typeface.body)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Chrome.Typeface.rowIcon)
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                }
                .buttonStyle(ChromePlainStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Chrome.Metric.control)
        .background(Chrome.Colour.fill, in: RoundedRectangle(cornerRadius: Chrome.Metric.radius))
    }
}

// MARK: - Progress

/// Spinners and bars. The Mac's spinner is eight spokes turning in steps, at
/// 10/16/32pt for mini/small/regular (`NSProgressIndicator`); iOS draws its
/// own spokes at its own sizes. A bar is a 6pt track filled with the accent.
struct ChromeProgressStyle: ProgressViewStyle {
    enum Kind { case automatic, circular, linear }
    var kind: Kind = .automatic

    func makeBody(configuration: Configuration) -> some View {
        ProgressBody(configuration: configuration, kind: kind)
    }

    private struct ProgressBody: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            let fraction = configuration.fractionCompleted
            let linear = kind == .linear || (kind == .automatic && fraction != nil)
            VStack(spacing: 6) {
                if linear {
                    ChromeProgressBar(fraction: fraction)
                } else {
                    ChromeSpinner(size: spinnerSize)
                }
                configuration.label
                    .font(Chrome.Style.subheadline)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                configuration.currentValueLabel
                    .font(Chrome.Style.subheadline)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
            }
        }

        private var spinnerSize: CGFloat {
            switch controlSize {
            case .mini: return 10
            case .small: return 16
            default: return 32
            }
        }
    }
}

/// Eight spokes, turning a spoke at a time.
struct ChromeSpinner: View {
    var size: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 12) % 8
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let age = (index - step + 8) % 8
                    Capsule()
                        .fill(Chrome.Colour.secondaryLabel)
                        .frame(width: max(size * 0.09, 1.5), height: size * 0.28)
                        .offset(y: -size * 0.36)
                        .rotationEffect(.degrees(Double(index) * 45))
                        .opacity(1 - Double(age) * 0.1)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("In progress")
    }
}

/// A determinate bar, or an indeterminate one that sweeps.
struct ChromeProgressBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Chrome.Colour.trackOff)
                if let fraction {
                    Capsule().fill(.tint).frame(width: width * min(max(fraction, 0), 1))
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(.tint)
                            .frame(width: width * 0.3)
                            .offset(x: (width * 1.3) * t - width * 0.3)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 6)
        .frame(minWidth: 60)
    }
}

// MARK: - Grouping

/// A disclosure group: a 9pt chevron in a 14pt slot, the label beside it, the
/// content indented below — the sidebar's disclosure, for anything else that
/// folds.
struct ChromeDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Chrome.Colour.tertiaryLabel)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 14, height: 14)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(ChromePlainStyle())
            .accessibilityAddTraits(.isHeader)
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 18)
            }
        }
    }
}

/// A name and its value: the name on the left in the label colour, the value
/// on the right in the secondary colour — the Mac's grouped-form row.
struct ChromeLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.label
                .foregroundStyle(Chrome.Colour.label)
            Spacer(minLength: 8)
            configuration.content
                .foregroundStyle(Chrome.Colour.secondaryLabel)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A label: the glyph and the title 6pt apart, as the Mac spaces them.
struct ChromeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// A rule. `Divider` is a different colour and thickness on each platform,
/// and knows its axis from a stack this cannot see, so it is said.
struct ChromeDivider: View {
    var axis: Axis = .horizontal

    init(_ axis: Axis = .horizontal) { self.axis = axis }

    var body: some View {
        Rectangle()
            .fill(Chrome.Colour.separator)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

// MARK: - Viewports

extension View {
    /// A scrolling list is a **viewport**: its ideal size is a fixed, nominal
    /// one — never its content's (S1, `docs/layout-architecture.md`).
    ///
    /// A `ScrollView` reports the height of everything in it as its ideal, so a
    /// 2,000-note tree asked its column for 2,000 rows' height, and the column
    /// its window — the inflation that once put the top of a note above the
    /// window, unreachable. The `NSOutlineView` these lists replaced answered
    /// `viewportSizeThatFits` (320×240 when asked for an ideal); this is the
    /// same answer for a SwiftUI one, and it still fills whatever it is given.
    /// `ShellViewportTests.noteOutlineDoesNotInflateTheShell` holds the sidebar
    /// to it.
    func viewport() -> some View {
        frame(minWidth: 0, idealWidth: 320, maxWidth: .infinity,
              minHeight: 0, idealHeight: 240, maxHeight: .infinity)
    }
}

// MARK: - Forms

/// A settings form — the Mac's grouped `Form`, drawn: a scrolling column on
/// the content colour, 20pt from the edges, sections 30pt apart. Replaces
/// `Form { … }.formStyle(.grouped)`, which on iOS is 17pt rows in 44pt cells
/// on a grey ground.
struct ChromeForm<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.chromeFormScrolls) private var scrolls

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if scrolls {
            ScrollView(.vertical) { sections }
                .viewport()
                .background(Chrome.Colour.content)
        } else {
            sections.background(Chrome.Colour.content)
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 30) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// Whether a `ChromeForm` scrolls: always, except in an offscreen render
    /// (`ScreenRenderTests`) — `ImageRenderer` does not draw what is inside a
    /// scroll view, so a page rendered that way looked empty when it was not.
    @Entry var chromeFormScrolls: Bool = true
}

/// A section of a `ChromeForm`: a 13pt bold header, its rows in a box of
/// radius 12 with a rule between each, and an 11pt footer. Each direct child
/// of the content is a row, as in a `Form` — so the call site reads exactly as
/// a `Section` did.
struct ChromeSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer

    init(@ViewBuilder content: @escaping () -> Content,
         @ViewBuilder header: @escaping () -> Header,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.content = content
        self.header = header
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if Header.self != EmptyView.self {
                header()
                    .font(Chrome.Style.headline)
                    .foregroundStyle(Chrome.Colour.label)
                    .padding(.horizontal, 10)
            }
            Group(subviews: content()) { rows in
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            if row.id != rows.first?.id {
                                Rectangle()
                                    .fill(Chrome.Colour.groupSeparator)
                                    .frame(height: 1)
                                    .padding(.horizontal, 10)
                            }
                            row
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Chrome.Colour.groupFill))
                }
            }
            if Footer.self != EmptyView.self {
                footer()
                    .font(Chrome.Style.subheadline)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
        }
    }
}

extension ChromeSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension ChromeSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension ChromeSection where Header == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.init(content: content, header: { Text(title) }, footer: footer)
    }
}

extension ChromeSection where Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder header: @escaping () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension ChromeSection where Header == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

// MARK: - Empty states

/// Nothing to show, and what to do about it: a 40pt light glyph, a 17pt
/// semibold title, 13pt secondary text, any actions below. Replaces
/// `ContentUnavailableView`, which is drawn at each platform's own sizes.
struct ChromeEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: Text? = nil
    @ViewBuilder var actions: () -> Actions

    init(_ title: String, systemImage: String, description: Text? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Chrome.Colour.tertiaryLabel)
                .accessibilityHidden(true)
            Text(title)
                .font(Chrome.Style.sized(17, .semibold))
                .foregroundStyle(Chrome.Colour.label)
                .multilineTextAlignment(.center)
            if let description {
                description
                    .font(Chrome.Style.body)
                    .foregroundStyle(Chrome.Colour.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension ChromeEmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

// MARK: - Sheets

/// A sheet's own bar: its title centred in 13pt semibold, the way out on the
/// left and the way forward on the right, on the chrome colour with a rule
/// below — **at the top on both platforms**, as the window's bar is. A
/// `NavigationStack` title bar is 17pt semibold between tinted text buttons
/// on iOS and a titled toolbar on the Mac.
struct ChromeSheetBar<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            ChromeLine(title, size: 13, weight: .semibold)
                .padding(.horizontal, 90)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                leading()
                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, Chrome.Metric.barPadding)
        .frame(height: Chrome.Metric.barHeight)
        .background(Chrome.Colour.chrome)
        .overlay(alignment: .bottom) { ChromeDivider() }
    }
}

extension View {
    /// A sheet at a size the app chooses, on the content colour — the same size
    /// on the Mac and the iPad: `.fitted` so the iPad sizes the sheet to it as
    /// the Mac does, instead of its own form-sheet size. On a phone the sheet
    /// *is* the screen, and a fixed size left bands of nothing above and below
    /// it, so there it fills.
    func chromeSheetFrame(width: CGFloat, height: CGFloat) -> some View {
        modifier(ChromeSheetFrame(width: width, height: height))
            .background(Chrome.Colour.content)
            .presentationSizing(.fitted)
            .presentationBackground(Chrome.Colour.content)
    }

    /// The app's controls, fonts and colours as the defaults for everything
    /// below — applied at every window's root (`ThemedRoot`), so a control
    /// that names no style of its own is already the app's rather than the
    /// platform's.
    func chromeDefaults() -> some View {
        self
            .font(Chrome.Style.body)
            .lineHeight(Chrome.lineHeight)
            .foregroundStyle(Chrome.Colour.label)
            .buttonStyle(ChromePushStyle())
            .toggleStyle(ChromeSwitchStyle())
            .progressViewStyle(ChromeProgressStyle())
            .disclosureGroupStyle(ChromeDisclosureGroupStyle())
            .labeledContentStyle(ChromeLabeledContentStyle())
            .labelStyle(ChromeLabelStyle())
    }
}

private struct ChromeSheetFrame: ViewModifier {
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        #if os(macOS)
        // A Mac sheet takes its content's size, so the size is the frame.
        content.frame(width: width, height: height)
        #else
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // An iPad sheet is the system's size unless told to fit its
            // content; `.fitted` takes this ideal size — the Mac's.
            content.frame(idealWidth: width, maxWidth: width, idealHeight: height, maxHeight: height)
        }
        #endif
    }
}

// MARK: - Links and colours

/// A link in the accent, opened with the environment's `openURL` — `Link` is
/// the Mac's link blue there and the tint on iOS.
struct ChromeLink: View {
    let title: String
    let destination: URL
    @Environment(\.openURL) private var openURL

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Button(title) { openURL(destination) }
            .buttonStyle(ChromeLinkStyle())
            .accessibilityAddTraits(.isLink)
    }
}

/// A colour well drawn by the app — a 38×22 swatch with a rim — over the
/// system's own picker, which is kept only to open the OS's colour panel. The
/// system wells share nothing: a bezelled rectangle on the Mac, a ring of
/// hues on iOS.
struct ChromeColorWell: View {
    let title: String
    @Binding var selection: Color
    var supportsOpacity = false

    init(_ title: String, selection: Binding<Color>, supportsOpacity: Bool = false) {
        self.title = title
        self._selection = selection
        self.supportsOpacity = supportsOpacity
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(selection)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Chrome.Colour.fieldBorder, lineWidth: 1))
                .frame(width: 38, height: 22)
                .allowsHitTesting(false)
            ColorPicker(title, selection: $selection, supportsOpacity: supportsOpacity)
                .labelsHidden()
                .frame(width: 38, height: 22)
                .scaleEffect(1.4)
                .opacity(0.011)
        }
        .frame(width: 38, height: 22)
        .clipped()
        .accessibilityLabel(title)
    }
}

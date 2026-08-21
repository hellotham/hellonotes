//
//  AppearanceSettingsSections.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Theme, accent, text size and text width — written once, for both settings
//  screens.
//
//  They were written twice: `AppearanceSettingsView` (a Preferences tab) and a
//  stretch of `iOSSettingsView`, drawing the same four groups over the same
//  `AppearanceSettings`. Duplicated settings screens are how a setting quietly
//  stops existing on one platform, and this pair had already lost three —
//  Reading width, Editor width and Wrap guide were on the Mac's screen and not
//  on the iPad's, and were fixed earlier in this audit by adding a second copy
//  of each control rather than by removing the reason a second copy was needed.
//
//  This is that reason removed. What stays per-screen is the container — a
//  Preferences tab against a `NavigationStack` of settings — and the two groups
//  that belong to one platform's chrome: the Mac's accent row is a line of
//  swatches, the iPad's is an adaptive grid, because 44pt targets do not fit on
//  one line at sheet width. The controls themselves are the same controls.
//

import SwiftUI

/// The Appearance / Accent / Text size / Text width sections, for a `Form` on
/// either platform.
struct AppearanceSettingsSections: View {
    @Bindable var settings: AppearanceSettings

    /// Whether the accent swatches lay out as a single row (a Preferences
    /// window has the width) or an adaptive grid (a sheet does not, and the
    /// targets are 44pt). A layout question, so the caller answers it.
    var accentLayout: AccentLayout = .row

    enum AccentLayout { case row, grid }

    private let swatchAccents: [AppearanceSettings.Accent] =
        [.multicolor, .lavender, .blue, .purple, .pink, .red, .orange, .yellow, .green, .graphite]

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.mode) {
                ForEach(AppearanceSettings.Mode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            caption("“Auto” follows the system light/dark setting.")

            Toggle("Increase contrast", isOn: $settings.increaseContrast)
            caption("Deepens the accent color and makes colored text easier to read.")
        }

        Section("Accent color") {
            switch accentLayout {
            case .row:
                HStack(spacing: 10) {
                    ForEach(swatchAccents) { swatch($0) }
                    customSwatch
                }
                .padding(.vertical, 2)
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 6) {
                    ForEach(swatchAccents) { swatch($0) }
                }
                ColorPicker(selection: $settings.customAccent, supportsOpacity: false) {
                    Label("Custom color", systemImage: "eyedropper")
                }
                .onChange(of: settings.customAccent) { _, _ in settings.accent = .custom }
            }
        }

        Section("Text size") {
            HStack(spacing: 12) {
                Text("A").font(.footnote).foregroundStyle(.secondary)
                Slider(value: $settings.textScale,
                       in: AppearanceSettings.minScale...AppearanceSettings.maxScale)
                Text("A").font(.title2).foregroundStyle(.secondary)
                Button("Reset") { settings.textScale = 1.0 }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(abs(settings.textScale - 1.0) < 0.001)
            }
            // A live specimen, so the slider shows what it is doing rather than
            // asking you to close settings and look.
            Text("The quick brown fox jumps over the lazy dog.")
                .font(.body)
                .scaleEffect(settings.textScale, anchor: .leading)
                .frame(height: 22 * settings.textScale, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.default, value: settings.textScale)
            caption("Scales the note editor and preview.")
        }

        // Reading and editing want different widths, so they get different
        // settings (docs/layout-architecture.md, decision 5).
        Section("Text width") {
            Picker("Reading width", selection: $settings.readingWidth) {
                ForEach(ReadingWidth.allCases, id: \.self) { width in
                    Text(width.label).tag(width)
                }
            }
            caption("How wide a line gets in Reading mode. A comfortable measure is about 80 characters; the column is centred in the pane.")

            Picker("Editor width", selection: $settings.editorWidth) {
                ForEach(EditorWidth.allCases, id: \.self) { width in
                    Text(width.label).tag(width)
                }
            }
            caption("How much of the pane you write in. Full uses the whole pane, left-aligned — tables and diagrams need the room.")

            Picker("Wrap guide", selection: $settings.wrapGuide) {
                ForEach(AppearanceSettings.wrapGuideChoices, id: \.self) { columns in
                    Text(columns == 0 ? "Off" : "\(columns) characters").tag(columns)
                }
            }
            caption("A line you can see while editing, not a wrap point — text still runs to the edge of the pane.")

            Picker("Sort notes by", selection: $settings.noteSortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Label(order.rawValue, systemImage: order.systemImage).tag(order)
                }
            }
            caption("How notes are ordered inside each folder of the sidebar. Folders always come first, sorted by name.")

            Toggle("Show note title", isOn: $settings.showInlineTitle)
            caption("Shows the file's name above the note as a heading. Editing it renames the file and updates every link to it.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func swatch(_ accent: AppearanceSettings.Accent) -> some View {
        Button {
            settings.accent = accent
        } label: {
            Circle()
                .fill(accent.swatch)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .strokeBorder(.primary.opacity(settings.accent == accent ? 0.9 : 0), lineWidth: 2)
                        .padding(-3)
                )
                .overlay {
                    if accent == .multicolor {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(accent.label)
        .accessibilityLabel("\(accent.label) accent")
        .accessibilityAddTraits(settings.accent == accent ? [.isButton, .isSelected] : .isButton)
    }

    private var customSwatch: some View {
        ColorPicker(selection: $settings.customAccent, supportsOpacity: false) {
            EmptyView()
        }
        .labelsHidden()
        .overlay(
            Circle()
                .strokeBorder(.primary.opacity(settings.accent == .custom ? 0.9 : 0), lineWidth: 2)
                .padding(-3)
        )
        .onChange(of: settings.customAccent) { _, _ in settings.accent = .custom }
        .help("Custom color")
    }
}

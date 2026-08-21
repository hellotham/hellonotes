//
//  AppearanceSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//

#if os(macOS)
import SwiftUI

/// The "Appearance" preferences tab: light / dark / auto, an accent colour
/// (macOS-style swatches plus a custom colour), and a text-size slider.
struct AppearanceSettingsView: View {
    @Bindable var settings: AppearanceSettings

    private let swatchAccents: [AppearanceSettings.Accent] =
        [.multicolor, .lavender, .blue, .purple, .pink, .red, .orange, .yellow, .green, .graphite]

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.mode) {
                    ForEach(AppearanceSettings.Mode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text("“Auto” follows the system light/dark setting.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Increase contrast", isOn: $settings.increaseContrast)
                Text("Deepens the accent color and makes colored text easier to read.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Accent color") {
                HStack(spacing: 10) {
                    ForEach(swatchAccents) { accent in
                        swatch(accent)
                    }
                    customSwatch
                }
                .padding(.vertical, 2)
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
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.body)
                    .scaleEffect(settings.textScale, anchor: .leading)
                    .frame(height: 22 * settings.textScale, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.default, value: settings.textScale)
            }

            // Reading and editing want different widths, so they get different
            // settings (docs/layout-architecture.md, decision 5).
            Section("Text width") {
                Picker("Reading width", selection: $settings.readingWidth) {
                    ForEach(ReadingWidth.allCases, id: \.self) { width in
                        Text(width.label).tag(width)
                    }
                }
                Text("How wide a line gets in Reading mode. A comfortable measure is about 80 characters; the column is centred in the pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Editor width", selection: $settings.editorWidth) {
                    ForEach(EditorWidth.allCases, id: \.self) { width in
                        Text(width.label).tag(width)
                    }
                }
                Text("How much of the pane you write in. Full uses the whole pane, left-aligned — tables and diagrams need the room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Wrap guide", selection: $settings.wrapGuide) {
                    ForEach(AppearanceSettings.wrapGuideChoices, id: \.self) { columns in
                        Text(columns == 0 ? "Off" : "\(columns) characters").tag(columns)
                    }
                }
                Text("A line you can see while editing, not a wrap point — text still runs to the edge of the pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Sort notes by", selection: $settings.noteSortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Label(order.rawValue, systemImage: order.systemImage).tag(order)
                    }
                }
                Text("How notes are ordered inside each folder of the sidebar. Folders always come first, sorted by name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show note title", isOn: $settings.showInlineTitle)
                Text("Shows the file's name above the note as a heading. Editing it renames the file and updates every link to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ accent: AppearanceSettings.Accent) -> some View {
        Button {
            settings.accent = accent
        } label: {
            Circle()
                .fill(accent.swatch)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(settings.accent == accent ? 0.9 : 0), lineWidth: 2)
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
            Circle().strokeBorder(.primary.opacity(settings.accent == .custom ? 0.9 : 0), lineWidth: 2)
                .padding(-3)
        )
        .onChange(of: settings.customAccent) { _, _ in settings.accent = .custom }
        .help("Custom color")
    }
}
#endif

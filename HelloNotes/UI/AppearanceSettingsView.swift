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
        [.multicolor, .blue, .purple, .pink, .red, .orange, .yellow, .green, .graphite]

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
            }

            Section("Accent Color") {
                HStack(spacing: 10) {
                    ForEach(swatchAccents) { accent in
                        swatch(accent)
                    }
                    customSwatch
                }
                .padding(.vertical, 2)
            }

            Section("Text Size") {
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

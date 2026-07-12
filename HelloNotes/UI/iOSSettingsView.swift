//
//  iOSSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  iOS Settings sheet. macOS hosts these in the Preferences window (⌘,), which
//  has no iOS counterpart — so the sidebar menu offers this sheet instead:
//  appearance (theme / accent / text size) plus the note-taking conventions
//  (attachments, daily notes, templates) shared with macOS via @AppStorage.
//

#if os(iOS)
import SwiftUI

struct iOSSettingsView: View {
    @Bindable var settings: AppearanceSettings
    @Environment(\.dismiss) private var dismiss

    @AppStorage("attachmentFolder") private var attachmentFolder = "assets"
    @AppStorage("dailyNoteFolder") private var dailyNoteFolder = ""
    @AppStorage("dailyDateFormat") private var dailyDateFormat = "yyyy-MM-dd"
    @AppStorage("templatesFolder") private var templatesFolder = "Templates"

    private let swatchAccents: [AppearanceSettings.Accent] =
        [.multicolor, .lavender, .blue, .purple, .pink, .red, .orange, .yellow, .green, .graphite]

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.mode) {
                        ForEach(AppearanceSettings.Mode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Increase contrast", isOn: $settings.increaseContrast)
                }

                Section("Accent Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 10) {
                        ForEach(swatchAccents) { accent in
                            swatch(accent)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Text Size") {
                    HStack(spacing: 12) {
                        Text("A").font(.footnote).foregroundStyle(.secondary)
                        Slider(value: $settings.textScale,
                               in: AppearanceSettings.minScale...AppearanceSettings.maxScale)
                        Text("A").font(.title2).foregroundStyle(.secondary)
                    }
                    Button("Reset to Default") { settings.textScale = 1.0 }
                        .disabled(abs(settings.textScale - 1.0) < 0.001)
                }

                Section("Attachments") {
                    TextField("Pasted-image folder", text: $attachmentFolder, prompt: Text("Same folder as note"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Daily Notes") {
                    TextField("Folder", text: $dailyNoteFolder, prompt: Text("Collection root"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Date format", text: $dailyDateFormat, prompt: Text("yyyy-MM-dd"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Templates") {
                    TextField("Folder", text: $templatesFolder, prompt: Text("Templates"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func swatch(_ accent: AppearanceSettings.Accent) -> some View {
        Button {
            settings.accent = accent
        } label: {
            Circle()
                .fill(accent.swatch)
                .frame(width: 30, height: 30)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(settings.accent == accent ? 0.9 : 0), lineWidth: 2)
                        .padding(-3)
                )
                .overlay {
                    if accent == .multicolor {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accent.label) accent")
        .accessibilityAddTraits(settings.accent == accent ? [.isButton, .isSelected] : .isButton)
    }
}
#endif

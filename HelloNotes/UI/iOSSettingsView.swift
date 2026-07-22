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

    @State private var showDropbox = false
    @State private var showBox = false
    @State private var showGoogleDrive = false
    #if DEBUG
    @State private var showCloudDemo = false
    #endif

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
                    Text("Deepens the accent color and makes colored text easier to read.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Accent color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 6) {
                        ForEach(swatchAccents) { accent in
                            swatch(accent)
                        }
                    }
                    ColorPicker(selection: $settings.customAccent, supportsOpacity: false) {
                        Label("Custom color", systemImage: "eyedropper")
                    }
                    .onChange(of: settings.customAccent) { _, _ in settings.accent = .custom }
                }

                Section {
                    HStack(spacing: 12) {
                        Text("A").font(.footnote).foregroundStyle(.secondary)
                        Slider(value: $settings.textScale,
                               in: AppearanceSettings.minScale...AppearanceSettings.maxScale)
                        Text("A").font(.title2).foregroundStyle(.secondary)
                    }
                    Button("Reset") { settings.textScale = 1.0 }
                        .disabled(abs(settings.textScale - 1.0) < 0.001)
                } header: {
                    Text("Text size")
                } footer: {
                    Text("Scales the note editor and preview. Everything else follows the system text size in Settings > Display & Brightness.")
                }

                Section("Attachments") {
                    TextField("Pasted-image folder", text: $attachmentFolder, prompt: Text("Same folder as note"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Daily notes") {
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

                Section {
                    Button("Connect Dropbox…") { showDropbox = true }
                    Button("Connect Box…") { showBox = true }
                    Button("Connect Google Drive…") { showGoogleDrive = true }
                    #if DEBUG
                    Button("Cloud Demo (Mock)…") { showCloudDemo = true }
                    #endif
                } header: {
                    Text("Cloud (direct API)")
                } footer: {
                    Text("Browse and edit notes straight over a provider's API, without a sync folder. Dropbox needs an app key in Info.plist (DropboxAppKey).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showDropbox) {
                NavigationStack { RemoteBrowserView(store: DropboxStore()) }
            }
            .sheet(isPresented: $showBox) {
                NavigationStack { RemoteBrowserView(store: BoxStore()) }
            }
            .sheet(isPresented: $showGoogleDrive) {
                NavigationStack { RemoteBrowserView(store: GoogleDriveStore()) }
            }
            #if DEBUG
            .sheet(isPresented: $showCloudDemo) {
                NavigationStack { RemoteBrowserView(store: MockRemoteStore()) }
            }
            #endif
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
                // The visual stays 30 pt; the tappable area meets the 44 pt
                // minimum hit target.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accent.label) accent")
        .accessibilityAddTraits(settings.accent == accent ? [.isButton, .isSelected] : .isButton)
    }
}
#endif

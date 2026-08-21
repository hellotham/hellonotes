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
    /// The focused collection's Git service, if it is in a repository.
    /// `GitSettingsView` and `GitAccountsStore` were never Mac-specific — the
    /// view imports nothing but SwiftUI and the store nothing but Foundation;
    /// only the settings *window* was macOS, so iPad could read history in the
    /// inspector and never configure the remote it was reading from.
    var git: GitService?
    var accounts: GitAccountsStore?
    @Environment(\.dismiss) private var dismiss
    /// So a browsed folder can be promoted to a sidebar collection here too —
    /// the same action macOS has had. Without it the iOS browser could only ever
    /// edit notes one at a time, in place.
    @Environment(Library.self) private var library

    /// Mirrors a browsed cloud folder into a sidebar collection. Captures the
    /// library itself rather than `self`, which is a view struct.
    private var addRemoteCollection: AddRemoteCollection {
        let library = self.library
        return { store, remoteRoot, displayName, progress in
            try await library.openRemote(store: store, remoteRoot: remoteRoot,
                                         displayName: displayName, progress: progress)
        }
    }


    @State private var showDropbox = false
    @State private var showBox = false
    @State private var showGoogleDrive = false
    @State private var showOneDrive = false
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

                // Reading and editing want different widths, so they get
                // different settings (docs/layout-architecture.md, decision 5).
                //
                // These three were stored and synced on iOS from the start and
                // read by nothing: the measure was applied by a `private func`
                // on the macOS-only `NoteEditorView`, and the wrap guide was
                // drawn by the AppKit text view only. So the settings existed
                // on iPad, moved, persisted, and changed nothing on screen.
                Section("Text width") {
                    Picker("Reading width", selection: $settings.readingWidth) {
                        ForEach(ReadingWidth.allCases, id: \.self) { width in
                            Text(width.label).tag(width)
                        }
                    }
                    Text("How wide a line gets in Preview. A comfortable measure is about 80 characters; the column is centred in the pane.")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Editor width", selection: $settings.editorWidth) {
                        ForEach(EditorWidth.allCases, id: \.self) { width in
                            Text(width.label).tag(width)
                        }
                    }
                    Text("How much of the pane you write in. Full uses the whole pane, left-aligned — tables and diagrams need the room.")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Wrap guide", selection: $settings.wrapGuide) {
                        ForEach(AppearanceSettings.wrapGuideChoices, id: \.self) { columns in
                            Text(columns == 0 ? "Off" : "\(columns) characters").tag(columns)
                        }
                    }
                    Text("A line you can see while editing, not a wrap point — text still runs to the edge of the pane.")
                        .font(.caption).foregroundStyle(.secondary)

                    Picker("Sort notes by", selection: $settings.noteSortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Label(order.rawValue, systemImage: order.systemImage).tag(order)
                        }
                    }
                    Text("How notes are ordered inside each folder of the sidebar. Folders always come first, sorted by name.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Show note title", isOn: $settings.showInlineTitle)
                    Text("Shows the file's name above the note as a heading. Editing it renames the file and updates every link to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let git, let accounts {
                    Section("Git") {
                        NavigationLink {
                            GitSettingsView(store: accounts, git: git)
                                .navigationTitle("Git")
                        } label: {
                            Label("Repository & Accounts", systemImage: "arrow.trianglehead.branch")
                        }
                    }
                }

                FolderConventionSections()

                Section {
                    Button("Connect Dropbox…") { showDropbox = true }
                    Button("Connect Box…") { showBox = true }
                    Button("Connect Google Drive…") { showGoogleDrive = true }
                    Button("Connect OneDrive…") { showOneDrive = true }
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
                NavigationStack { RemoteBrowserView(store: DropboxStore(), onAddAsCollection: addRemoteCollection) }
            }
            .sheet(isPresented: $showBox) {
                NavigationStack { RemoteBrowserView(store: BoxStore(), onAddAsCollection: addRemoteCollection) }
            }
            .sheet(isPresented: $showGoogleDrive) {
                NavigationStack { RemoteBrowserView(store: GoogleDriveStore(), onAddAsCollection: addRemoteCollection) }
            }
            .sheet(isPresented: $showOneDrive) {
                NavigationStack { RemoteBrowserView(store: OneDriveStore(), onAddAsCollection: addRemoteCollection) }
            }
            #if DEBUG
            .sheet(isPresented: $showCloudDemo) {
                NavigationStack { RemoteBrowserView(store: MockRemoteStore(), onAddAsCollection: addRemoteCollection) }
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

//
//  SettingsView.swift
//  HelloNotes
//
//  The app's settings — one file, two containers.
//
//  There were two: `GeneralSettingsView.swift` (a tabbed Preferences window) and
//  `iOSSettingsView.swift` (a sheet), each gated to its platform. The *controls*
//  in them are already shared — `AppearanceSettingsSections` and
//  `FolderConventionSections` — so what was left in each file was arrangement,
//  and arrangement is where the two genuinely differ: macOS Preferences is a
//  tab bar of panes and iOS Settings is one scrolling list. Keeping them in one
//  file with an `#else` says that out loud, and stops a *setting* being added to
//  one arrangement and forgotten in the other, which is how Reading width,
//  Editor width and Wrap guide came to be Mac-only in the first place.
//
//  One thing was not arrangement: **Acknowledgements had no iOS route.**
//  `AcknowledgementsView` has never been gated; it was simply only ever placed
//  in the Mac's tab bar, so the licences and credits the app ships were
//  unreachable on iPad.
//

import SwiftUI
#if !os(macOS)
import UIKit
#endif

#if os(macOS)
/// The Preferences window (⌘,): a tabbed container for all app settings. AI /
/// LLM provider configuration also remains reachable from the Assistant window.
struct PreferencesView: View {
    /// Shared LLM configuration, so the AI tab and the Assistant sheet edit the
    /// same providers, keys and defaults.
    var llmSettings: LLMSettings
    /// App-wide theming (appearance, accent, text size).
    var appearance: AppearanceSettings

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AppearanceSettingsView(settings: appearance)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            LLMSettingsForm(settings: llmSettings)
                .tabItem { Label("AI", systemImage: "sparkles") }

            AcknowledgementsView()
                .tabItem { Label("Acknowledgements", systemImage: "heart") }
        }
        .frame(width: 560, height: 640)
    }
}

struct GeneralSettingsView: View {
    // Attachments, daily notes and templates now live in
    // `FolderConventionSettings.swift`, shared with `iOSSettingsView` — the two
    // screens had drifted into describing the same `@AppStorage` keys
    // differently, which is a difference in the app, not in the platform.
    var body: some View {
        Form {
            FolderConventionSections()
        }
        .formStyle(.grouped)
    }
}
#else
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

    var body: some View {
        NavigationStack {
            Form {
                // The same four groups the Mac's Preferences tab draws, from
                // `AppearanceSettingsSections`. They were written twice over
                // the same object, which is how three of them existed on one
                // platform and not the other.
                AppearanceSettingsSections(settings: settings, accentLayout: .grid)

                if let git, let accounts {
                    Section("Git") {
                        NavigationLink {
                            // The title is `GitSettingsView`'s own now — set
                            // here it was a second name for one screen.
                            GitSettingsView(store: accounts, git: git)
                        } label: {
                            Label("Repository & Accounts", systemImage: "arrow.trianglehead.branch")
                        }
                    }
                }

                FolderConventionSections()

                Section {
                    NavigationLink {
                        AcknowledgementsView()
                            .navigationTitle("Acknowledgements")
                    } label: {
                        Label("Acknowledgements", systemImage: "heart")
                    }
                } footer: {
                    // `AcknowledgementsView` has never been gated — it was just
                    // only ever placed in the Mac's tab bar, so the licences and
                    // credits this app ships were unreachable on iPad.
                    Text("Open-source licences and credits.")
                }

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

}
#endif

/// The app's settings, however this platform presents them.
///
/// `PreferencesView` (a tabbed Preferences window) and `iOSSettingsView` (a
/// pushed `Form`) are genuinely different presentations of one screen — a
/// `Settings` scene has no iOS spelling and a `NavigationStack` sheet is not
/// what ⌘, opens. They already draw the same four groups from
/// `AppearanceSettingsSections` and `FolderConventionSections`.
///
/// What was missing was a name the shell could say without knowing which
/// platform it was on. Without it the shell's sheet stack had to be gated, and
/// a gated sheet stack is how the Mac lost `largeFolderAlert` the moment
/// anything else in that chain moved.
struct AppSettingsView: View {
    var llmSettings: LLMSettings
    var appearance: AppearanceSettings
    var git: GitService?
    var accounts: GitAccountsStore?

    var body: some View {
        #if os(macOS)
        PreferencesView(llmSettings: llmSettings, appearance: appearance)
        #else
        iOSSettingsView(settings: appearance, git: git, accounts: accounts)
        #endif
    }
}

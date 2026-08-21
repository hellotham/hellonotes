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

}
#endif

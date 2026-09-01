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
    /// Git hosting accounts. Shared with the window rather than owned here —
    /// see `HelloNotesApp.gitAccounts`.
    var gitAccounts: GitAccountsStore
    /// The two voluntary purchases. Owned by the app, not by this window —
    /// `Settings` is its own scene and gets no environment from the main one.
    var store: StoreService

    /// A repository-less service for the Settings tab.
    ///
    /// `GitSettingsView`'s repository sections need a `GitService`; its
    /// **Accounts** section needs only the store. Settings is not opened
    /// "inside" a collection, so it gets a bare service and shows accounts —
    /// which is the part that has to be reachable before any repository exists.
    @State private var settingsGit = GitService()

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            AppearanceSettingsView(settings: appearance)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            // Credentials belong in Settings on both platforms. iOS has had
            // this ("Repository & Accounts"); macOS reached `GitSettingsView`
            // only from the inspector's Git pane, which requires a collection
            // that is already a repository — so the credentials needed to
            // *clone* one were behind having cloned one.
            GitSettingsView(store: gitAccounts, git: settingsGit)
                .tabItem { Label("Git", systemImage: "arrow.trianglehead.branch") }

            LLMSettingsForm(settings: llmSettings)
                .tabItem { Label("AI", systemImage: "sparkles") }

            // Both platforms, for the reason the file's header gives: a screen
            // that exists on one shell is a screen nobody looked at on the
            // other. This one also carries the App Store disclosures, so
            // "reachable on macOS" is a review requirement, not a nicety.
            SupportSettingsView(store: store)
                .tabItem { Label("Support", systemImage: "heart") }
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
    /// Provider configuration and API keys.
    ///
    /// Present here for the same reason Git is: **credentials belong in
    /// Settings on both platforms.** macOS has had an AI tab since the
    /// Preferences window existed; iOS reached the identical form only from
    /// the editor band's "AI Settings…" and the command palette, so someone
    /// looking for their keys where keys live found appearance, Git and
    /// folders — and no mention of AI at all.
    var llmSettings: LLMSettings
    /// The focused collection's Git service, if it is in a repository.
    /// `GitSettingsView` and `GitAccountsStore` were never Mac-specific — the
    /// view imports nothing but SwiftUI and the store nothing but Foundation;
    /// only the settings *window* was macOS, so iPad could read history in the
    /// inspector and never configure the remote it was reading from.
    var git: GitService?
    var accounts: GitAccountsStore?
    /// The two voluntary purchases — see `PreferencesView.store`.
    var store: StoreService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // The same four groups the Mac's Preferences tab draws, from
                // `AppearanceSettingsSections`. They were written twice over
                // the same object, which is how three of them existed on one
                // platform and not the other.
                AppearanceSettingsSections(settings: settings, accentLayout: .grid)

                Section("AI") {
                    NavigationLink {
                        // The very same form the Mac's AI tab shows — not a
                        // second, smaller iOS spelling of it. Entering a key
                        // and removing one are the same two controls here.
                        //
                        // **Not wrapped in a `Form`.** `LLMSettingsForm` is one
                        // already (`.formStyle(.grouped)`), and `Form { Form { … } }`
                        // collapses: the screen rendered as a clipped stub with
                        // a half-drawn "Defaults" label and nothing else. It
                        // shipped that way in build 11 because the screen was
                        // added and never looked at.
                        LLMSettingsForm(settings: llmSettings)
                            .navigationTitle("AI")
                    } label: {
                        Label("Providers & API Keys", systemImage: "sparkles")
                    }
                }

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

                Section("Support") {
                    NavigationLink {
                        // `SupportSettingsView` is a `Form` already, exactly as
                        // `LLMSettingsForm` is. Pushed as a destination that is
                        // correct; wrapped in another `Form` it would render as
                        // the same clipped stub the AI screen shipped as in
                        // build 11.
                        SupportSettingsView(store: store)
                    } label: {
                        Label("Support HelloNotes", systemImage: "heart")
                    }
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
    var store: StoreService

    var body: some View {
        #if os(macOS)
        // A store is always available here — the shell owns one whether or not
        // a collection is open, which is the whole point of the Git tab.
        PreferencesView(llmSettings: llmSettings, appearance: appearance,
                        gitAccounts: accounts ?? GitAccountsStore(), store: store)
        #else
        iOSSettingsView(settings: appearance, llmSettings: llmSettings,
                        git: git, accounts: accounts, store: store)
        #endif
    }
}

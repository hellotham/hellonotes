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

/// A page of Settings, so a route can open Settings *at* one.
///
/// AI settings are a page of Settings, not a screen of their own. There was a
/// second one — a sheet titled "AI Settings" holding the same form — because
/// neither a `Settings` window nor a settings sheet can be opened at a page, and
/// the Assistant needed to send people to its model choice. So a menu offered
/// "AI Settings…" beside "Settings…", two doors that read as two places. Every
/// route to AI settings now opens Settings, at AI.
enum SettingsPage: String {
    case general, appearance, git, ai, support

    /// The Mac's tab, stored: `openSettings` takes no argument, so a route
    /// sets this and then opens the window.
    static let storageKey = "settingsPage"
}

#if os(macOS)
/// The Preferences window (⌘,): a tabbed container for all app settings.
struct PreferencesView: View {
    /// Shared AI settings, so the AI tab and the Assistant's sheet edit the
    /// same choices.
    var intelligenceSettings: IntelligenceSettings
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

    @AppStorage(SettingsPage.storageKey) private var page = SettingsPage.general

    var body: some View {
        TabView(selection: $page) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPage.general)

            AppearanceSettingsView(settings: appearance)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsPage.appearance)

            // Credentials belong in Settings on both platforms. iOS has had
            // this ("Repository & Accounts"); macOS reached `GitSettingsView`
            // only from the inspector's Git pane, which requires a collection
            // that is already a repository — so the credentials needed to
            // *clone* one were behind having cloned one.
            GitSettingsView(store: gitAccounts, git: settingsGit)
                .tabItem { Label("Git", systemImage: "arrow.trianglehead.branch") }
                .tag(SettingsPage.git)

            IntelligenceSettingsForm(settings: intelligenceSettings)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsPage.ai)

            // Both platforms, for the reason the file's header gives: a screen
            // that exists on one shell is a screen nobody looked at on the
            // other. This one also carries the App Store disclosures, so
            // "reachable on macOS" is a review requirement, not a nicety.
            SupportSettingsView(store: store)
                .tabItem { Label("Support", systemImage: "heart") }
                .tag(SettingsPage.support)
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
    /// Which model does what.
    ///
    /// Present here for the same reason Git is: **settings belong in Settings
    /// on both platforms.** macOS has had an AI tab since the Preferences
    /// window existed; iOS once reached the identical form only from the
    /// editor band's "AI Settings…" and the command palette, so someone looking
    /// for it where settings live found appearance, Git and folders — and no
    /// mention of AI at all.
    var intelligenceSettings: IntelligenceSettings
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
    /// Starts at the page a route asked for, already pushed, so "AI Settings…"
    /// lands on AI with Settings behind it.
    @State private var path: [SettingsPage]

    init(settings: AppearanceSettings, intelligenceSettings: IntelligenceSettings,
         git: GitService?, accounts: GitAccountsStore?, store: StoreService,
         page: SettingsPage? = nil) {
        self.settings = settings
        self.intelligenceSettings = intelligenceSettings
        self.git = git
        self.accounts = accounts
        self.store = store
        _path = State(initialValue: page.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                // The same four groups the Mac's Preferences tab draws, from
                // `AppearanceSettingsSections`. They were written twice over
                // the same object, which is how three of them existed on one
                // platform and not the other.
                AppearanceSettingsSections(settings: settings, accentLayout: .grid)

                Section("AI") {
                    NavigationLink(value: SettingsPage.ai) {
                        Label("Models", systemImage: "sparkles")
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
                        // `IntelligenceSettingsForm` is. Pushed as a destination that is
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
            .navigationDestination(for: SettingsPage.self) { page in
                if page == .ai {
                    // The very same form the Mac's AI tab shows — not a
                    // second, smaller iOS spelling of it.
                    //
                    // **Not wrapped in a `Form`.** `IntelligenceSettingsForm` is one
                    // already (`.formStyle(.grouped)`), and `Form { Form { … } }`
                    // collapses: the screen rendered as a clipped stub with
                    // a half-drawn "Defaults" label and nothing else. It
                    // shipped that way in build 11 because the screen was
                    // added and never looked at.
                    IntelligenceSettingsForm(settings: intelligenceSettings)
                        .navigationTitle("AI")
                }
            }
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
    var intelligenceSettings: IntelligenceSettings
    var appearance: AppearanceSettings
    var git: GitService?
    var accounts: GitAccountsStore?
    var store: StoreService
    /// The page to open at. The Mac's is stored instead (`SettingsPage.storageKey`),
    /// because the window ⌘, opens takes no argument.
    var page: SettingsPage? = nil

    var body: some View {
        #if os(macOS)
        // A store is always available here — the shell owns one whether or not
        // a collection is open, which is the whole point of the Git tab.
        PreferencesView(intelligenceSettings: intelligenceSettings, appearance: appearance,
                        gitAccounts: accounts ?? GitAccountsStore(), store: store)
        #else
        iOSSettingsView(settings: appearance, intelligenceSettings: intelligenceSettings,
                        git: git, accounts: accounts, store: store, page: page)
        #endif
    }
}

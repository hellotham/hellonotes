//
//  GeneralSettingsView.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  The app's Preferences window (⌘,). Hosts library-wide preferences that aren't
//  tied to the LLM or Git sheets — where pasted attachments go, and the daily-
//  note / template folder conventions. All values are persisted via @AppStorage.
//

#if os(macOS)
import SwiftUI

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

#endif

//
//  HelloNotesApp.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

@main
struct HelloNotesApp: App {
    @State private var library = Library()
    /// Shared LLM configuration (providers, keys, intelligence provider), so
    /// every window — including standalone note windows — sees the same settings.
    @State private var llmSettings = LLMSettings()
    /// App-wide theming (appearance, accent, text size), applied at every root.
    @State private var appearance = AppearanceSettings()

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacContentView()
                .environment(library)
                .environment(llmSettings)
                .environment(appearance)
                .themedRoot(appearance)
            #elseif os(iOS)
            iOSContentView()
                .environment(library)
                .environment(appearance)
                .themedRoot(appearance)
            #endif
        }

        #if os(macOS)
        // Standalone single-note windows, opened via `openWindow(value: NoteRef(url))`.
        // NoteRef (not URL) keeps macOS from treating this as a document scene.
        WindowGroup(for: NoteRef.self) { $ref in
            if let ref {
                NoteWindowView(fileURL: ref.url)
                    .environment(library)
                    .environment(llmSettings)
                    .environment(appearance)
                    .themedRoot(appearance)
            }
        }

        // Preferences window (⌘,): General, Appearance, and AI tabs.
        Settings {
            PreferencesView(llmSettings: llmSettings, appearance: appearance)
                .themedRoot(appearance)
        }
        #endif
    }
}

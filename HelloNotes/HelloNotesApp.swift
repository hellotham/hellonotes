//
//  HelloNotesApp.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

@main
struct HelloNotesApp: App {
    @State private var indexer = WorkspaceIndexer()
    /// Shared LLM configuration (providers, keys, intelligence provider), so
    /// every window — including standalone note windows — sees the same settings.
    @State private var llmSettings = LLMSettings()

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacContentView()
                .environment(indexer)
                .environment(llmSettings)
            #elseif os(iOS)
            iOSContentView()
                .environment(indexer)
            #endif
        }

        #if os(macOS)
        // Standalone single-note windows, opened via `openWindow(value: NoteRef(url))`.
        // NoteRef (not URL) keeps macOS from treating this as a document scene.
        WindowGroup(for: NoteRef.self) { $ref in
            if let ref {
                NoteWindowView(fileURL: ref.url)
                    .environment(indexer)
                    .environment(llmSettings)
            }
        }

        // Preferences window (⌘,).
        Settings {
            GeneralSettingsView()
        }
        #endif
    }
}

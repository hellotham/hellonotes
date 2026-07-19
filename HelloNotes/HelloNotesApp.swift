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
    #if os(macOS)
    /// Drains pending editor autosaves on ⌘Q before the process exits.
    @NSApplicationDelegateAdaptor(TerminationGuard.self) private var terminationGuard
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            #if os(macOS)
            MacContentView()
                .environment(library)
                .environment(llmSettings)
                .environment(appearance)
                .themedRoot(appearance)
            #else
            // iOS, iPadOS, and visionOS (all configured platforms) share the
            // UIKit-backed content view — without this, a visionOS build would
            // render an empty WindowGroup body.
            iOSContentView()
                .environment(library)
                .environment(appearance)
                .themedRoot(appearance)
            #endif
        }
        #if os(macOS)
        .commands { HelloNotesCommands() }
        #endif

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

        // Exploration / reference surfaces live in windows, not sheets, so
        // they can stay open beside the notes they describe.
        Window("Graph", id: "graph") {
            GraphWindowView()
                .environment(library)
                .environment(appearance)
                .themedRoot(appearance)
        }
        .defaultSize(width: 760, height: 560)

        Window("Ask Library", id: "askLibrary") {
            LibraryChatWindowView()
                .environment(library)
                .environment(llmSettings)
                .environment(appearance)
                .themedRoot(appearance)
        }
        .defaultSize(width: 560, height: 640)

        Window("Assistant", id: "assistant") {
            AssistantWindowView()
                .environment(library)
                .environment(llmSettings)
                .environment(appearance)
                .themedRoot(appearance)
        }
        .defaultSize(width: 560, height: 680)

        WindowGroup(for: MindMapRef.self) { $ref in
            if let ref {
                MindMapWindowView(rootURL: ref.url)
                    .environment(library)
                    .environment(appearance)
                    .themedRoot(appearance)
            }
        }
        .defaultSize(width: 720, height: 540)

        // Preferences window (⌘,): General, Appearance, and AI tabs.
        Settings {
            PreferencesView(llmSettings: llmSettings, appearance: appearance)
                .themedRoot(appearance)
        }
        #endif
    }
}

//
//  HelloNotesApp.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import SwiftUI

@main
struct HelloNotesApp: App {
    @State private var library: Library
    /// Deep-link / App-Intents / Services navigation entry point.
    @State private var router: NavigationRouter
    /// Shared LLM configuration (providers, keys, intelligence provider), so
    /// every window — including standalone note windows — sees the same settings.
    @State private var llmSettings = LLMSettings()
    /// App-wide theming (appearance, accent, text size), applied at every root.
    @State private var appearance = AppearanceSettings()
    /// Built editor documents, kept above every view that shows one so tab
    /// switches and shell rearrangements don't re-parse the note or lose the
    /// caret. See EditorDocumentStore.
    @State private var documents = EditorDocumentStore()
    #if os(macOS)
    /// Drains pending editor autosaves on ⌘Q before the process exits.
    @NSApplicationDelegateAdaptor(TerminationGuard.self) private var terminationGuard
    #endif

    init() {
        let lib = Library()
        _library = State(initialValue: lib)
        _router = State(initialValue: NavigationRouter(library: lib))
        HelloNotesTips.configure()
        CloudPrefs.shared.start()   // mirror preference keys via iCloud KV
    }

    #if os(macOS)
    /// Mirrors a browsed cloud folder into a sidebar collection, handing
    /// progress and failures back to the browser that asked for it.
    ///
    /// This was `Task { try? await library.openRemote(…) }` at five call sites:
    /// the `try?` discarded every error, and nothing awaited or reported the
    /// result — so an expired token, a 403 on a shared folder and a complete
    /// success all looked identical, and identical to the button being dead.
    private var addRemoteCollection: AddRemoteCollection {
        // Capture the library itself, not `self` — the App struct holds property
        // wrappers and has no business outliving this scene's body evaluation.
        let library = self.library
        return { store, remoteRoot, displayName, progress in
            try await library.openRemote(store: store, remoteRoot: remoteRoot,
                                         displayName: displayName, progress: progress)
        }
    }
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            #if os(macOS)
            MacContentView()
                .environment(library)
                .environment(router)
                .environment(llmSettings)
                .environment(appearance)
                .environment(documents)
                .themedRoot(appearance)
                .onOpenURL { router.handle($0) }
            #else
            // iOS, iPadOS, and visionOS (all configured platforms) share the
            // UIKit-backed content view — without this, a visionOS build would
            // render an empty WindowGroup body.
            iOSContentView()
                .environment(library)
                .environment(router)
                .environment(appearance)
                .environment(documents)
                .themedRoot(appearance)
                .onOpenURL { router.handle($0) }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)   // roomy first launch (not the 860pt min floor)
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
                    .environment(documents)
                    .themedRoot(appearance)
            }
        }

        // Exploration / reference surfaces live in windows, not sheets, so
        // they can stay open beside the notes they describe.
        Window("Graph", id: "graph") {
            GraphWindowView()
                .environment(library)
                .environment(appearance)
                .environment(documents)
                .themedRoot(appearance)
        }
        .defaultSize(width: 760, height: 560)

        Window("Ask Library", id: "askLibrary") {
            LibraryChatWindowView()
                .environment(library)
                .environment(llmSettings)
                .environment(appearance)
                .environment(documents)
                .themedRoot(appearance)
        }
        .defaultSize(width: 560, height: 640)

        Window("Assistant", id: "assistant") {
            AssistantWindowView()
                .environment(library)
                .environment(llmSettings)
                .environment(appearance)
                .environment(documents)
                .themedRoot(appearance)
        }
        .defaultSize(width: 560, height: 680)

        // Direct-API cloud browser (Phase 4): connect a provider over REST and
        // edit notes without a sync folder. Uses DropboxStore (needs an app key
        // in Info.plist); a DEBUG-only demo window drives the same UI with an
        // in-memory MockRemoteStore.
        Window("Cloud Notes (Direct)", id: "remoteBrowser") {
            RemoteBrowserView(store: DropboxStore(), onAddAsCollection: addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        Window("Box (Direct)", id: "remoteBrowserBox") {
            RemoteBrowserView(store: BoxStore(), onAddAsCollection: addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        Window("Google Drive (Direct)", id: "remoteBrowserGDrive") {
            RemoteBrowserView(store: GoogleDriveStore(), onAddAsCollection: addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        Window("OneDrive (Direct)", id: "remoteBrowserOneDrive") {
            RemoteBrowserView(store: OneDriveStore(), onAddAsCollection: addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        #if DEBUG
        Window("Cloud Demo", id: "remoteBrowserDemo") {
            RemoteBrowserView(store: MockRemoteStore(), onAddAsCollection: addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)
        #endif

        WindowGroup(for: MindMapRef.self) { $ref in
            if let ref {
                MindMapWindowView(rootURL: ref.url)
                    .environment(library)
                    .environment(appearance)
                    .environment(documents)
                    .themedRoot(appearance)
            }
        }
        .defaultSize(width: 720, height: 540)

        // Preferences window (⌘,): General, Appearance, and AI tabs.
        Settings {
            PreferencesView(llmSettings: llmSettings, appearance: appearance)
                .themedRoot(appearance)
        }

        // Menu-bar quick capture: jot a line into today's daily note without
        // switching to the app (Phase B — highest daily-value Mac feature).
        MenuBarExtra("HelloNotes", systemImage: "note.text") {
            QuickCaptureView(router: router)
                .themedRoot(appearance)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

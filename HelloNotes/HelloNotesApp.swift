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
    /// Drains pending editor autosaves before the app goes away — ⌘Q on the
    /// Mac, resigning active on iOS.
    ///
    /// The adaptor is macOS-only because `NSApplicationDelegateAdaptor` is; the
    /// *guard* is not, and was, which meant `TerminationGuard.current` was nil
    /// on iPad and every registration the shells made there did nothing.
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(TerminationGuard.self) private var terminationGuard
    #else
    @State private var terminationGuard = TerminationGuard()
    #endif

    init() {
        // First, so it is watching before anything else has a chance to block
        // the main actor. No-op unless HN_STALL_LOG is set on a Debug build.
        MainActorWatchdog.start()
        // Print a symbolicated stack for any uncaught exception (Debug only).
        ExceptionLogger.install()
        let lib = Library()
        _library = State(initialValue: lib)
        _router = State(initialValue: NavigationRouter(library: lib))
        HelloNotesTips.configure()
        CloudPrefs.shared.start()   // mirror preference keys via iCloud KV
    }

    /// Every app-wide observable, injected in one place.
    ///
    /// The macOS and iOS scenes used to carry their own lists, and the iOS one
    /// was missing `llmSettings` — so **every iOS launch died** in SwiftUI's
    /// environment lookup (`No Observable object of type LLMSettings found`)
    /// the moment `iOSContentView` read it. Nothing caught it: both platforms
    /// compile, the macOS app is unaffected, and the crash only appears when
    /// the app is actually run on a device.
    ///
    /// Two parallel lists that must agree is the defect; one list is the fix.
    /// Windows that need only a subset get the extras harmlessly, and in
    /// exchange can never crash by reading something the scene forgot.
    private func rooted(_ content: some View) -> some View {
        content
            .environment(library)
            .environment(router)
            .environment(llmSettings)
            .environment(appearance)
            .environment(documents)
            .themedRoot(appearance)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            #if os(macOS)
            rooted(MacContentView())
                .onOpenURL { router.handle($0) }
            #else
            // iOS, iPadOS, and visionOS (all configured platforms) share the
            // UIKit-backed content view — without this, a visionOS build would
            // render an empty WindowGroup body.
            rooted(iOSContentView())
                .onOpenURL { router.handle($0) }
            #endif
        }
        // Both platforms: iPadOS 26 gives a scene a resizable window too, so
        // gating this meant the iPad's first window opened at whatever the
        // system chose while the Mac's opened at a size the app had picked.
        .defaultSize(width: 1100, height: 720)   // roomy first launch (not the 860pt min floor)
        // iPadOS builds its menu bar from a scene's `.commands` exactly as
        // macOS does. Gating this was gating the iPad's whole menu bar and
        // every keyboard shortcut with it — no ⌘B, no ⌘F, no View menu.
        .commands { HelloNotesCommands() }

        // Standalone single-note windows, opened via `openWindow(value: NoteRef(url))`.
        // NoteRef (not URL) keeps macOS from treating this as a document scene.
        //
        // Cross-platform: iPadOS builds a second scene from the same call, and
        // this was gated to macOS while `AppCommands` went on offering "Open in
        // New Window" on both — an item that drew, enabled, and did nothing.
        WindowGroup(for: NoteRef.self) { $ref in
            if let ref {
                rooted(NoteWindowView(fileURL: ref.url))
            }
        }

        #if os(macOS)

        // Exploration / reference surfaces live in windows, not sheets, so
        // they can stay open beside the notes they describe.
        Window("Graph", id: "graph") {
            rooted(GraphWindowView())
        }
        .defaultSize(width: 760, height: 560)

        Window("Ask Library", id: "askLibrary") {
            rooted(LibraryChatWindowView())
        }
        .defaultSize(width: 560, height: 640)

        Window("Assistant", id: "assistant") {
            rooted(AssistantWindowView())
        }
        .defaultSize(width: 560, height: 680)

        // Direct-API cloud browser (Phase 4): connect a provider over REST and
        // edit notes without a sync folder. Uses DropboxStore (needs an app key
        // in Info.plist); a DEBUG-only demo window drives the same UI with an
        // in-memory MockRemoteStore.
        Window("Cloud Notes (Direct)", id: CloudBrowser.dropbox.windowID) {
            RemoteBrowserView(store: DropboxStore(), onAddAsCollection: library.addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        Window("Box (Direct)", id: CloudBrowser.box.windowID) {
            RemoteBrowserView(store: BoxStore(), onAddAsCollection: library.addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        Window("Google Drive (Direct)", id: CloudBrowser.googleDrive.windowID) {
            RemoteBrowserView(store: GoogleDriveStore(), onAddAsCollection: library.addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        Window("OneDrive (Direct)", id: CloudBrowser.oneDrive.windowID) {
            RemoteBrowserView(store: OneDriveStore(), onAddAsCollection: library.addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)

        #if DEBUG
        Window("Cloud Demo", id: "remoteBrowserDemo") {
            RemoteBrowserView(store: MockRemoteStore(), onAddAsCollection: library.addRemoteCollection)
                .themedRoot(appearance)
        }
        .defaultSize(width: 480, height: 580)
        #endif

        WindowGroup(for: MindMapRef.self) { $ref in
            if let ref {
                rooted(MindMapWindowView(rootURL: ref.url))
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

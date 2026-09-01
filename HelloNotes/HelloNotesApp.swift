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
    /// Git hosting accounts, at app level because **Settings needs them too**.
    ///
    /// This was `@State` inside `ContentView`, which put the only copy inside a
    /// window — so the Settings scene could not offer them, and on macOS the
    /// single route to `GitSettingsView` was the inspector's Git pane. That
    /// pane needs a collection that is already a repository, and adding an
    /// account is what lets you *clone* one: you needed a repository to get the
    /// credentials for getting a repository.
    @State private var gitAccounts = GitAccountsStore()
    /// The two voluntary purchases (Champion, Commercial). App-level for the
    /// same reason `gitAccounts` is: the Settings scene is not inside a window,
    /// so a store owned by `ContentView` would be invisible to the one screen
    /// that sells anything. It also has to exist from launch — a transaction
    /// approved while the app was closed arrives on `Transaction.updates`
    /// once, and only a listener that is already running receives it.
    @State private var store = StoreService()
    /// Built editor documents, kept above every view that shows one so tab
    /// switches and shell rearrangements don't re-parse the note or lose the
    /// caret. See EditorDocumentStore.
    @State private var documents = EditorDocumentStore()
    @State private var liveBuffer = LiveBuffer()
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
            .environment(gitAccounts)
            .environment(store)
            .environment(documents)
            .environment(liveBuffer)
            .themedRoot(appearance)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            // One shell. It was `MacContentView` or `iOSContentView` here,
            // each defined inside a one-sided `#if`, which is what made every
            // divergence between them invisible from the other side.
            rooted(ContentView())
                .onOpenURL { router.handle($0) }
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

        // Exploration / reference surfaces open beside the notes they describe,
        // on **both** platforms. `WindowGroup(id:)` rather than the singleton
        // `Window`, which is macOS-only: the iPad has held a second scene since
        // note windows shipped, and these were simply never given one. Which of
        // window or sheet a canvas gets is `AuxiliaryPresentation`, keyed on
        // width rather than on the OS.
        //
        // `for: AuxiliaryRef.self` is what keeps them singletons. A plain
        // `WindowGroup(id:)` opens a *new* window on every `openWindow(id:)`,
        // where `Window` refocused the existing one — so three clicks on Graph
        // gave three Graph windows, each with its own state. A group keyed on a
        // value dedupes on that value, and `AuxiliaryOpener` passes the scene's
        // own id, one value per scene.
        WindowGroup(id: AuxiliarySurface.graph.windowID, for: AuxiliaryRef.self) { _ in
            rooted(GraphWindowView())
        }
        .defaultSize(AuxiliarySurface.graph.defaultSize)

        WindowGroup(id: AuxiliarySurface.askLibrary.windowID, for: AuxiliaryRef.self) { _ in
            rooted(LibraryChatWindowView())
        }
        .defaultSize(AuxiliarySurface.askLibrary.defaultSize)

        WindowGroup(id: AuxiliarySurface.assistant.windowID, for: AuxiliaryRef.self) { _ in
            rooted(AssistantWindowView())
        }
        .defaultSize(AuxiliarySurface.assistant.defaultSize)

        WindowGroup(for: MindMapRef.self) { $ref in
            if let ref {
                rooted(MindMapWindowView(rootURL: ref.url))
            }
        }
        .defaultSize(width: 720, height: 540)

        #if os(macOS)
        // Preferences window (⌘,): General, Appearance, and AI tabs.
        //
        // `Settings` and `MenuBarExtra` are macOS scene *types* with no iOS
        // spelling — there is no menu bar to extend and no Preferences scene to
        // register. What matters for parity is that the surfaces behind them
        // are reachable on both, and they are: Settings is a sheet the iPad
        // shell presents from the same command, and Quick Capture is a command
        // in `HelloNotesCommands` and the palette on both platforms. The
        // menu-bar item is an extra *route* on the platform that has the
        // concept, not a feature the iPad lacks.
        Settings {
            PreferencesView(llmSettings: llmSettings, appearance: appearance,
                            gitAccounts: gitAccounts, store: store)
                .themedRoot(appearance)
        }

        // Menu-bar quick capture: jot a line into today's daily note without
        // switching to the app (Phase B — highest daily-value Mac feature).
        MenuBarExtra("HelloNotes", systemImage: "note.text") {
            QuickCaptureView(router: router)
                .themedRoot(appearance)
        }
        .menuBarExtraStyle(.window)
        #else
        // The other branch, stated rather than left silent: `Settings` and
        // `MenuBarExtra` are macOS scene *types* with no iOS spelling — there
        // is no Preferences scene to register and no menu bar to extend. What
        // matters for parity is that the surfaces behind them are reachable on
        // both, and they are. Settings is a sheet the shell presents from the
        // same `showSettings` state (`AppSettingsView`), and Quick Capture is a
        // command in `HelloNotesCommands` and the palette, ⌃⌘K, on both. The
        // menu-bar item is an extra *route* on the platform that has the
        // concept, not a feature the other one lacks.
        #endif
    }
}

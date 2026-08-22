//
//  AppCommands.swift
//  HelloNotes
//
//  Created by Chris Tham on 13/7/2026.
//
//  The macOS menu bar. The main window publishes its actions through a focused
//  scene value (`AppActions`), so every command below targets whichever window
//  is frontmost and greys out when it doesn't apply. This is the app's primary
//  discoverability surface: every major feature lives here with its shortcut.
//

//  **Cross-platform.** This file was `#if os(macOS)` end to end. iPadOS builds
//  its menu bar from a scene's `.commands` exactly as macOS does, so gating the
//  file gated the iPad's entire menu bar *and* every keyboard shortcut with it:
//  no ⌘B, no ⌘F, no View menu. What is genuinely Mac-only — windows, the
//  Finder, NSWorkspace — is gated item by item instead, so an iPad never shows
//  a command it cannot honour.

import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The provider windows **Connect Over the Web** opens.
///
/// The four window ids were string literals in three places — the scene
/// declarations, the menu, and (once the palette learned these commands) a
/// third. Three copies of a string that must match exactly, where a typo opens
/// nothing at all and reports nothing either.
enum CloudBrowser: String, CaseIterable, Identifiable {
    case dropbox = "remoteBrowser"
    case box = "remoteBrowserBox"
    case googleDrive = "remoteBrowserGDrive"
    case oneDrive = "remoteBrowserOneDrive"
    /// A mock store, for exercising the browser without an account. Debug-only,
    /// but a *case* rather than a separate menu item, because a separate item
    /// is what made it macOS-only: it opened a `Window` directly, and iOS has
    /// no scene for one. Through the shared case it takes whichever route the
    /// platform already uses for the four real providers.
    #if DEBUG
    case mock = "remoteBrowserDemo"
    #endif

    var id: String { rawValue }
    var windowID: String { rawValue }

    /// What the window is called.
    ///
    /// `RemoteBrowserView` sets no `navigationTitle`, and these scenes lost the
    /// titles they carried as `Window("Box (Direct)", …)` when they became
    /// `WindowGroup`s — a `WindowGroup` with no title falls back to the app's
    /// name, so opening all four gave four windows called "HelloNotes".
    var windowTitle: String { "\(displayName) (Direct)" }

    var displayName: String {
        switch self {
        case .dropbox: "Dropbox"
        case .box: "Box"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        #if DEBUG
        case .mock: "Cloud Demo (Mock)"
        #endif
        }
    }

    /// The store this browser drives.
    ///
    /// Here rather than at the call site because macOS opens four `Window`s
    /// that each name their own store and iOS presents one sheet that has to
    /// pick — and a second mapping from case to store is how the two platforms
    /// end up disagreeing about which provider "Box" means.
    @MainActor
    func makeStore() -> any RemoteStore {
        switch self {
        case .dropbox: DropboxStore()
        case .box: BoxStore()
        case .googleDrive: GoogleDriveStore()
        case .oneDrive: OneDriveStore()
        #if DEBUG
        case .mock: MockRemoteStore()
        #endif
        }
    }
}

/// The actions a HelloNotes window offers to the menu bar.
///
/// **Every command belongs here**, including ones whose implementation is a
/// notification post or an `openWindow` call. The command palette is generated
/// from this value, so a command that reaches the menu bar by some other route
/// is invisible to the palette — which is exactly the discoverability problem
/// the palette exists to solve, reintroduced one command at a time. A
/// fact-check found eight that had gone that way.
struct AppActions {
    var canNewNote: Bool
    var newNote: () -> Void
    var todaysNote: () -> Void
    var openLauncher: () -> Void
    var canOpenQuickly: Bool
    var openQuickly: () -> Void
    var canGraph: Bool
    var graphView: () -> Void
    var canAsk: Bool
    var askLibrary: () -> Void
    var assistant: () -> Void
    /// Close the active editor tab. Enabled only when more than one tab is
    /// open, so ⌘W falls through to the standard window Close otherwise.
    var canCloseTab: Bool
    var closeTab: () -> Void
    /// Send a Markdown formatting command to the active editor. `nil` when no
    /// editable note is focused (Format menu greys out).
    var format: ((FormatAction) -> Void)?
    /// Actions on the selected note; `nil` when no note is selected.
    var note: NoteMenuActions?
    /// Rebuild the focused collection's index from scratch, ignoring the cache
    /// — the safety valve if the index ever looks stale. `nil` when no
    /// collection is open.
    var rescan: (() -> Void)?
    /// Whether the focused collection lists non-note files, and a setter.
    /// `nil` when no collection is open.
    var showsNonNoteFiles: Bool?
    var setShowsNonNoteFiles: ((Bool) -> Void)?
    /// Browse the File-Provider mounts for a folder to open directly — the
    /// no-authentication path for a provider whose client is installed.
    var openCloudFolder: (() -> Void)?
    /// Ask a direct-API collection's provider what has changed. `nil` unless the
    /// focused collection is one. A command, so it belongs in a menu rather than
    /// only in a status bar that hides whenever a note is open.
    var refreshCloudCollection: (() -> Void)?
    /// Jot a line into today's daily note without leaving what you are doing.
    ///
    /// A command on both platforms. On the Mac it existed *only* in the
    /// menu-bar extra, so someone who hides the menu-bar icon — or who simply
    /// looks in the app's menus, which is where commands live — could not reach
    /// it at all. The iPad had it in the toolbar menu. The menu-bar item stays
    /// as an extra route on the platform that has the concept.
    var quickCapture: (() -> Void)? = nil
    /// Templates in the focused collection, and inserting one at the caret.
    ///
    /// Both are here rather than in `NoteMenuActions` because the list depends
    /// on the *collection* and the insertion on the *editor*, and a menu that
    /// offers a template while none is open would be a command that cannot run.
    /// Empty list ⇒ the submenu greys out.
    var templates: [TemplateRef] = []
    var insertTemplate: ((TemplateRef) -> Void)? = nil
    /// Show the command palette (⌘⇧P).
    var commandPalette: (() -> Void)?
    /// AI actions on the open note. `nil` when there is no note or no working
    /// provider — the menu greys out and the palette omits them entirely.
    var ai: AIActions?
    /// Walk this note's unmade links one at a time — Link / Skip / Never.
    ///
    /// Deliberately **not** inside `ai`: this is an exact text scan, so it works
    /// with no provider configured at all. Filing it with the AI actions would
    /// hide a working feature behind a setting it does not need.
    var reviewLinks: (() -> Void)?
    /// Write or research a **new** note. Also not inside `ai` — but for the
    /// opposite reason to `reviewLinks`: every action in there operates on the
    /// note you have open, and this one is how a note comes to exist. It sits
    /// in File beside New Note, which is where someone goes when they want a
    /// note, rather than in a menu they only open once they already have one.
    var composeNote: (() -> Void)?
    /// Open another main window.
    var newWindow: (() -> Void)?
    /// Toggle the editor's find bar. `nil` when no note is open.
    var find: (() -> Void)?
    /// Focus the library-wide search field.
    var searchAllCollections: () -> Void
    /// Connect a provider over its own API, for an account whose desktop client
    /// is not installed.
    var connectOverWeb: ((CloudBrowser) -> Void)?
    /// The editor presentation mode, and a setter — both surfaces read one
    /// value rather than each reaching for `@AppStorage` separately.
    var editorMode: EditorMode
    var setEditorMode: (EditorMode) -> Void
}

/// What the model can do *to the open note*.
///
/// These are note operations, so they live in the Note menu beside Rename and
/// Duplicate rather than in an "Intelligence" panel of their own. Each one's
/// **result** lands in the inspector tab that already owns that kind of
/// information — a summary in Outline, tags in Tags, links in References — so
/// the command is findable in one fixed place and its output is where you would
/// have gone looking for it anyway. That pairing is the whole point: an "AI
/// panel" is organised by which technology produced the answer, which is the one
/// fact a reader does not care about.
struct AIActions {
    /// Who is doing the work, so the menu can say so rather than implying magic.
    var providerName: String
    /// Summarise the note; lands at the top of the Outline tab.
    var summarize: () -> Void
    /// Suggest tags the note's content implies; lands in the Tags tab.
    var suggestTags: () -> Void
    /// Suggest notes worth linking to; lands in the References tab.
    var suggestLinks: () -> Void
    /// Rewrite or expand the whole note, reviewed before it replaces anything.
    var rewriteNote: () -> Void
}

/// Menu actions that act on the selected note.
struct NoteMenuActions {
    var isBookmarked: Bool
    var rename: () -> Void
    var duplicate: () -> Void
    var toggleBookmark: () -> Void
    var copyWikiLink: () -> Void
    /// Show the note in Finder or Files, whichever this platform has.
    /// Nil when the file cannot be revealed at all.
    var revealInFileManager: (() -> Void)?
    var openInNewWindow: (() -> Void)?
    var exportHTML: () -> Void
    var exportPDF: () -> Void
    var printNote: () -> Void
    var moveToTrash: () -> Void
}

extension FocusedValues {
    @Entry var appActions: AppActions?
}

/// File / Note / Format / View menu commands.
struct HelloNotesCommands: Commands {
    @FocusedValue(\.appActions) private var actions
    @Environment(\.openWindow) private var openWindow

    /// The editor view mode, shared with the editor's own picker.
    ///
    /// **One key.** It used to be two — `editorViewMode` on the Mac and
    /// `iosEditorViewMode` on iOS — justified on the grounds that reading the
    /// Mac's on iPad "silently disabled every Format command". That was the
    /// split describing its own symptom: this menu compared its key against
    /// what the iPad's shell wrote, and they were different keys.
    ///
    /// The split then produced a second, worse defect. `NoteEditorView` reads
    /// `editorViewMode` with no gate at all, and the iPad's detail column is
    /// `NoteEditorView` now — so the View menu wrote one key while the editor
    /// it controls read the other, and changing the mode on iPad changed
    /// nothing. Two keys for one setting is not a platform difference; it is
    /// two answers to one question.
    @AppStorage(EditorMode.storageKey) private var editorMode = EditorMode.edit.rawValue

    /// Formatting applies only in the live-editing mode with a note focused.
    private var canFormat: Bool {
        actions?.format != nil && actions?.note != nil && editorMode == EditorMode.edit.rawValue
    }

    /// The Help menu's destination. A literal, so this cannot actually be nil —
    /// but a shipped build shouldn't crash on a menu item over a typo, so it is
    /// unwrapped at the call site rather than force-unwrapped here.
    private let helpURL = URL(string: "https://github.com/hellotham/hellonotes")

    var body: some Commands {
        // MARK: App — About shows the splash (it carries the version, build,
        // and credits), staying up until clicked.
        // Both platforms: iPadOS builds its menu bar from these same commands,
        // so gating this removed the iPad's About box rather than describing a
        // platform that has none. See `SplashPresenter`.
        CommandGroup(replacing: .appInfo) {
            Button("About HelloNotes") { SplashPresenter.show(autoDismiss: false) }
        }

        // MARK: File — creation and opening. ⌘N makes a note (the app's
        // primary object, the Mail convention); New Window moves to ⌥⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }
                .keyboardShortcut("n")
                .disabled(!(actions?.canNewNote ?? false))
            // There is a second window on iPad: `WindowGroup(id: "main")` is
            // cross-platform and iPadOS makes another scene from it. The gate
            // here said "no second window to open on iPad" and was the only
            // thing making that true.
            Button("New Window") { actions?.newWindow?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(actions?.newWindow == nil)
            Button("Today's Note") { actions?.todaysNote() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(actions?.canNewNote ?? false))
            // ⌃⌘N — the New Note family, one modifier further out. ⌥⌘N is
            // already New Window.
            Button("New Note from a Prompt…") { actions?.composeNote?() }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(actions?.composeNote == nil)

            Divider()

            // ⌘O opens things (the HIG-reserved meaning); Open Quickly takes
            // ⇧⌘O, the Xcode convention.
            Button("Open…") { actions?.openLauncher() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Quick Capture…") { actions?.quickCapture?() }
                .keyboardShortcut("k", modifiers: [.command, .control])
                .disabled(actions?.quickCapture == nil)
            Button("Open Quickly…") { actions?.openQuickly() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!(actions?.canOpenQuickly ?? false))

            Divider()

            // The index cache makes launches instant; this is the escape hatch
            // that rebuilds it from scratch if it ever looks stale.
            Button("Rescan Collection") { actions?.rescan?() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(actions?.rescan == nil)

            Divider()

            // Deliberately no ⌘W here: SwiftUI won't reliably attach a key
            // equivalent that the standard Close item already owns. The main
            // window intercepts ⌘W itself while several tabs are open (view
            // shortcuts beat menu items), so ⌘W closes the tab then and the
            // window otherwise — the Safari/Xcode convention. This item is the
            // discoverable, clickable counterpart.
            //
            // **Not Mac-only.** This was gated `#if os(macOS)` under the
            // comment "iPad has no editor tab bar", which stopped being true
            // the day `iOSContentView` grew a `tabStrip` over the same shared
            // `EditorTabs` the Mac uses, close buttons and all. The gate left
            // the iPad with tabs it could open, close by touch, and reach from
            // no menu — so it gets the item on both platforms, greyed by
            // `canCloseTab` exactly as the Mac's is.
            Button("Close Tab") { actions?.closeTab() }
                .disabled(!(actions?.canCloseTab ?? false))
        }

        // MARK: File — export lives where macOS users expect it.
        CommandGroup(after: .importExport) {
            Button("Export as HTML…") { actions?.note?.exportHTML() }
                .disabled(actions?.note == nil)
            Button("Export as PDF…") { actions?.note?.exportPDF() }
                .disabled(actions?.note == nil)
            Divider()
            // The cheap path first. When a provider's client is installed its
            // files are already on this Mac as ordinary dataless paths, so a
            // collection there needs no sign-in, no token and no cache at all.
            Button("Command Palette…") { actions?.commandPalette?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions?.commandPalette == nil)
            Divider()
            Button("Open Cloud Folder…") { actions?.openCloudFolder?() }
                .disabled(actions?.openCloudFolder == nil)
            Button("Refresh Cloud Collection") { actions?.refreshCloudCollection?() }
                .disabled(actions?.refreshCloudCollection == nil)

            // Connecting over the provider's own API is the fallback, for an
            // account whose desktop client is not installed. All four browsers
            // have been on iOS since they were written — reachable only from
            // Settings, because this menu was gated and `connectOverWeb` was
            // nil on that platform.
            Menu("Connect Over the Web") {
                ForEach(CloudBrowser.allCases) { provider in
                    Button("\(provider.displayName)…") { actions?.connectOverWeb?(provider) }
                }
            }
            .disabled(actions?.connectOverWeb == nil)
        }

        // MARK: File — Print (⌘P), the standard menu item a notes app must have.
        CommandGroup(replacing: .printItem) {
            Button("Print…") { actions?.note?.printNote() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions?.note == nil)
        }

        // Find (⌘F) belongs in the Edit menu (HIG), not only on the editor toolbar.
        CommandGroup(after: .textEditing) {
            Button("Find…") { actions?.find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.find == nil)

            // ⌘F is find-*in-note*; searching the whole library is a different
            // question and takes Apple Notes' shortcut for it. The band's search
            // field is a plain `TextField` (shell-chrome.md D9) rather than
            // `.searchable`, so unlike the system control it gets no keyboard
            // route for free — this is that route.
            Button("Search All Collections") { actions?.searchAllCollections() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions == nil)
        }

        // MARK: Note — everything that acts on the selected note.
        CommandMenu("Note") {
            Button("Rename…") { actions?.note?.rename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.note == nil)
            Button("Duplicate") { actions?.note?.duplicate() }
                .keyboardShortcut("d")   // ⌘D = Duplicate (Finder convention)
                .disabled(actions?.note == nil)
            Button((actions?.note?.isBookmarked ?? false) ? "Remove Bookmark" : "Add Bookmark") {
                actions?.note?.toggleBookmark()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])   // ⇧⌘D (⌘D is Duplicate)
            .disabled(actions?.note == nil)

            Divider()

            // The AI actions, in the menu that owns the note rather than in a
            // panel of their own. Each names where its answer will appear, so
            // the menu teaches the inspector rather than replacing it.
            Button("Summarise Note") { actions?.ai?.summarize() }
                .disabled(actions?.ai == nil)
            Button("Suggest Tags") { actions?.ai?.suggestTags() }
                .disabled(actions?.ai == nil)
            Button("Suggest Links") { actions?.ai?.suggestLinks() }
                .disabled(actions?.ai == nil)
            Button("Rewrite or Expand Note…") { actions?.ai?.rewriteNote() }
                .disabled(actions?.ai == nil)
            Button("Review Links…") { actions?.reviewLinks?() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions?.reviewLinks == nil)

            Divider()

            // The templates folder has been a setting since the folder
            // conventions screen shipped, and this is the first thing that
            // reads it — see `Templates`. One menu, so both platforms get the
            // command from one place.
            Menu("Insert Template") {
                ForEach(actions?.templates ?? []) { template in
                    Button(template.title) { actions?.insertTemplate?(template) }
                }
            }
            .disabled(actions?.templates.isEmpty ?? true || actions?.insertTemplate == nil)

            Divider()

            Button("Copy Wiki Link") { actions?.note?.copyWikiLink() }
                .disabled(actions?.note == nil)
            // Not a Mac desktop concept after all: iPadOS makes a second scene
            // from the same `openWindow(value:)` call, and `iOSNoteWindowView`
            // now fills it. Disabled on the optional rather than gated on the
            // platform, so the item follows the capability instead of the OS.
            Button("Open in New Window") { actions?.note?.openInNewWindow?() }
                .disabled(actions?.note?.openInNewWindow == nil)
            // One command on both platforms. It was gated to macOS on the
            // grounds that iOS has no Finder — true, and not the point: iOS has
            // Files, it opens at a path, and "show me this file where it lives"
            // is a question both platforms can answer. See `FileReveal`.
            Button(FileReveal.revealTitle) { actions?.note?.revealInFileManager?() }
                .disabled(actions?.note?.revealInFileManager == nil)

            Divider()

            Button("Move to Trash") { actions?.note?.moveToTrash() }
                .keyboardShortcut(.delete, modifiers: .command)   // ⌘⌫ (destructive needs a modifier)
                .disabled(actions?.note == nil)

            Divider()

            Button(DictationController.shared.isRecording ? "Stop Dictation" : "Dictate to Daily Note") {
                DictationController.shared.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .control])   // ⌃⌘D (⌥⌘D is the system Dock shortcut)
            .disabled(!DictationController.shared.isSupported)
        }

        // MARK: Format — Markdown styling for the live editor.
        CommandMenu("Format") {
            Button("Bold") { actions?.format?(.bold) }
                .keyboardShortcut("b")
                .disabled(!canFormat)
            Button("Italic") { actions?.format?(.italic) }
                .keyboardShortcut("i")
                .disabled(!canFormat)
            Button("Strikethrough") { actions?.format?(.strikethrough) }
                .disabled(!canFormat)
            Button("Highlight") { actions?.format?(.highlight) }
                .disabled(!canFormat)
            Button("Inline Code") { actions?.format?(.inlineCode) }
                .disabled(!canFormat)

            Divider()

            // ⌥⌘1–3, the Apple Notes heading convention.
            ForEach(1...3, id: \.self) { level in
                Button("Heading \(level)") { actions?.format?(.heading(level)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
                    .disabled(!canFormat)
            }

            Divider()

            Button("Blockquote") { actions?.format?(.blockquote) }
                .disabled(!canFormat)
            // ⇧⌘7 / ⇧⌘9, the Apple Notes list shortcuts.
            Button("Bulleted List") { actions?.format?(.unorderedList) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
                .disabled(!canFormat)
            Button("Numbered List") { actions?.format?(.orderedList) }
                .keyboardShortcut("9", modifiers: [.command, .shift])
                .disabled(!canFormat)
        }

        // MARK: View — editor presentation and the app's overview surfaces.
        CommandGroup(before: .toolbar) {
            ForEach(Array(EditorMode.platformCases.enumerated()), id: \.element) { index, mode in
                Toggle(mode.label, isOn: Binding(
                    get: { actions?.editorMode == mode },
                    set: { if $0 { actions?.setEditorMode(mode) } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                .disabled(actions == nil)
            }

            Divider()

            Button("Graph View") { actions?.graphView() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!(actions?.canGraph ?? false))
            Button("Ask Library") { actions?.askLibrary() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!(actions?.canAsk ?? false))
            Button("Assistant") { actions?.assistant() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(actions == nil)

            Divider()

            // Whether the collection lists PDFs, images and other documents
            // alongside notes. A view choice, so it belongs in View — and a
            // command, so it cannot live in the sidebar (shell-chrome.md).
            Toggle("Show Non-Note Files", isOn: Binding(
                get: { actions?.showsNonNoteFiles ?? true },
                set: { actions?.setShowsNonNoteFiles?($0) }
            ))
            .disabled(actions?.showsNonNoteFiles == nil)

            Divider()
        }

        // MARK: Help — point the stock stub somewhere real. On both, for the
        // same reason as About: the iPad has this menu too, and opening a URL
        // is `FileReveal.openInDefaultApp` on either platform.
        CommandGroup(replacing: .help) {
            Button("HelloNotes Help") {
                if let helpURL { FileReveal.openInDefaultApp(helpURL) }
            }
        }
    }
}

// MARK: - Formatting bus names

extension Notification.Name {
    /// The per-document notification name for a formatting request. Scoped by
    /// `documentId` so a Format command reaches only the focused editor, never
    /// the same note open in another window.
}

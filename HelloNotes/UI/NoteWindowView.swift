//
//  NoteWindowView.swift
//  HelloNotes
//
//  A standalone window for a single note — one view, both platforms.
//
//  There were two: `NoteWindowView` (macOS) and `iOSNoteWindowView`, written
//  four weeks apart for the same job. They had drifted in the way this audit
//  keeps finding: the Mac's `openWikiLink` compared titles, while the iPad's had
//  been written later against the link graph and so resolved aliases and
//  relative paths the Mac's could not — a `[[Alias]]` opened a window on iPad
//  and did nothing on the Mac. Both go through `WikiLinkNavigation` now.
//
//  It owns its own `EditorModel`, as both did: a second window on the same note
//  is a second buffer, and sharing the main window's would make closing a tab
//  tear down a window's document. That editor is wired to the note's collection
//  as a tab's is, by the same code (`EditorWiring`, through `load`).
//
//  Renaming is deliberately absent. It rewrites every wiki link in the
//  collection and moves the file this window is built around; that belongs where
//  the sidebar can follow it, not in a window whose only subject would vanish
//  mid-edit.
//

import SwiftUI
import MarkdownEditor

struct NoteWindowView: View {
    let fileURL: URL

    @Environment(Library.self) private var library
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(IntelligenceSettings.self) private var intelligenceSettings
    @Environment(\.openWindow) private var openWindow

    @State private var editor = EditorModel()
    @State private var embedProvider = CollectionEmbedProvider()
    @State private var git = GitService()
    @State private var didLoad = false
    /// The note's links to and from other notes, as the main window finds
    /// them: the status bar's Links popover said "No References" for every
    /// note, because it was handed none (toolbars.md §14, item 5).
    @State private var references = NoteReferences()
    @State private var referenceSpotlight = SpotlightSearch()

    /// The collection this note belongs to — link resolution and completion are
    /// scoped to it, never to whatever the main window happens to be focused on.
    private var collection: Collection? { library.collection(containing: fileURL) }

    private var notes: [Note] { collection?.notes ?? [] }
    private var note: Note? { notes.first { $0.fileURL == fileURL } }
    private var title: String { note?.title ?? fileURL.deletingPathExtension().lastPathComponent }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { windowBar }
            .background(Chrome.Colour.content)
            // What the window is called — the Window menu, Mission Control, the
            // iPad's window switcher. No system bar draws it; `windowBar` does.
            .navigationTitle(title)
            .representingNoteFile(fileURL)
            .task {
                guard !didLoad else { return }
                didLoad = true
                embedProvider.update(notes: notes)
                // The note first, and the repository's status after it, not
                // awaited: a `git status` walks the whole working tree, and
                // until it had, the window said "This note could not be
                // opened" (as `Collection.activate` does it).
                if let note { await Self.load(note, into: editor, wiring: EditorWiring(library: library)) }
                if let root = collection?.rootURL {
                    git.rootURL = root
                    Task { await git.refreshStatus() }
                }
            }
            // Every time the window appears, not once with the load, because
            // both are undone when it goes. Drain this window's autosave
            // before the app goes away — the termination handshake awaits
            // only registered hooks, so without it an un-awaited `onDisappear`
            // flush is cut short and the last edit is lost — and hear about
            // changes on disk.
            .task(id: NoteReferences.key(note: note, in: collection)) {
                await references.refresh(note: note, in: collection, spotlight: referenceSpotlight)
            }
            .onAppear {
                TerminationGuard.current?.register(editor) { lettingGo in await editor.flush(lettingGo: lettingGo) }
                Self.observeExternalChanges(of: library, editor: editor)
            }
            .onDisappear {
                library.stopObservingExternalChanges(of: editor)
                // Waited for by a quit that comes before it lands, as the main
                // window's tabs are (`FlushRegistry.letGo`).
                if let termination = TerminationGuard.current {
                    termination.letGo(editor) { [editor] in await editor.flush() }
                } else {
                    Task { await editor.flush() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if editor.note != nil {
            // The full editor, not just the pane: a note window gets the find
            // bar, the mode switcher and the mode sheets, which the iPad's
            // window had none of because `NoteEditorView` was macOS-gated. No
            // `NavigationStack` around it: the mode switcher is in the editor's
            // own bottom bar, and a navigation bar is each platform's drawing.
            NoteEditorView(
                editor: editor,
                backlinks: references.backlinks,
                outgoingLinks: references.outgoingLinks,
                unlinkedMentions: references.unlinkedMentions,
                // The collection's own, which follows its notes and its saves
                // (`CollectionEmbedProvider.revision`); one of the window's
                // own only for a note in no open collection.
                embedProvider: collection?.embedProvider ?? embedProvider,
                git: git,
                // The repository's pane: without the collection the status
                // bar's Git button opened an empty popover.
                gitCollection: collection,
                linkCandidates: notes.map(\.title),
                tagCandidates: collection?.search.allTags() ?? [],
                onOpenWikiLink: openWikiLink,
                onOpenNote: { openWindow(value: NoteRef($0.fileURL)) },
                // A note window has no panel and no command bar, so the note's
                // commands stay in its bottom bar.
                commandsInBottomBar: true)
        } else {
            ChromeEmptyState("Note Unavailable", systemImage: "doc.text",
                             description: Text("This note could not be opened."))
        }
    }

    /// The window's bar: the main window's bar row (`shellBar`), drawn by the
    /// app — 40pt, the chrome grey, a rule below, and the window dragged by its
    /// background. It carries only the title; the note's commands are in the
    /// editor's bottom bar, which in the main window holds only the view modes
    /// (`NoteEditorView.commandsInBottomBar`). The title is
    /// centred on the window, as a title bar's is, and kept clear of the Mac's
    /// window buttons on both sides so it stays centred.
    private var windowBar: some View {
        ChromeLine(title, size: 13, weight: .semibold)
            .accessibilityAddTraits(.isHeader)
            // The window drags by its title too, as a title bar does.
            .allowsHitTesting(false)
            .padding(.horizontal, Chrome.Metric.barPadding + WindowControls.leadingInset)
            .frame(maxWidth: .infinity)
            .frame(height: Chrome.Metric.barHeight)
            .background(Chrome.Colour.chrome.windowDraggable())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Chrome.Colour.separator).frame(height: 1)
            }
    }

    /// Follow a `[[wiki link]]`, opening notes in their own windows.
    ///
    /// Through `WikiLinkNavigation`, so this window resolves a link exactly as
    /// the main one does. The Mac's copy compared titles and the iPad's used the
    /// link graph, so an alias opened a window on one platform and did nothing
    /// on the other. Create-on-miss is refused here: a link followed in a
    /// single-note window should not silently write a new note into the vault.
    private func openWikiLink(_ target: String) {
        Task {
            switch await WikiLinkNavigation.resolve(target: target,
                                                    in: collection,
                                                    current: note,
                                                    createOnMiss: false) {
            case .web(let url):
                ExternalURL.open(url)
            case .note(let destination, _):
                openWindow(value: NoteRef(destination.fileURL))
            case .none:
                break
            }
        }
    }
}

extension NoteWindowView {
    /// How a note window loads its note into its editor: the editor wired to
    /// the note's collection, and the note opened, exactly as a tab's are
    /// (`EditorWiring`).
    ///
    /// It made a bare editor and opened the note itself, so a cloud note still
    /// a placeholder in its collection's cache opened empty — and what was
    /// typed there was written over the placeholder, never uploaded, and
    /// replaced at the next download — and its saves were never registered as
    /// the app's own writes, never indexed, nor refused when the collection's
    /// folder had gone.
    static func load(_ note: Note, into editor: EditorModel, wiring: EditorWiring) async {
        wiring.wire(editor)
        await wiring.open(note, in: editor)
    }

    /// What a note window does when an open collection changes on disk: its
    /// editor reconciled, as a tab's is — a clean one reloads, one with unsaved
    /// edits raises the conflict banner. It was told nothing, and found out
    /// only when its next save found the file changed.
    ///
    /// And it catches up: what changed while the window was not listening is
    /// looked at as it starts — nothing, the first time, before its note loads.
    static func observeExternalChanges(of library: Library, editor: EditorModel) {
        library.observeExternalChanges(of: editor) { editor in
            Task { await editor.reconcileWithDisk() }
        }
        Task { [weak editor] in await editor?.reconcileWithDisk() }
    }
}

private extension View {
    #if os(macOS)
    /// A floor under the window's size, and the file the window represents —
    /// which the Window menu and Mission Control name — without adopting a
    /// document scene. (The title bar is hidden and the bar is the app's, so
    /// there is no proxy icon to carry it; the representation is what is left.)
    func representingNoteFile(_ fileURL: URL) -> some View {
        frame(minWidth: 480, minHeight: 400)
            .navigationDocument(fileURL)
    }
    #else
    /// Neither on iPadOS: the system sizes a scene there, not a frame inside
    /// it, and a scene names itself from its title.
    func representingNoteFile(_ fileURL: URL) -> some View { self }
    #endif
}

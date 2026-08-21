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
//  tear down a window's document.
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
    @Environment(LLMSettings.self) private var llmSettings
    @Environment(\.openWindow) private var openWindow

    @State private var editor = EditorModel()
    @State private var embedProvider = CollectionEmbedProvider()
    @State private var git = GitService()
    @State private var didLoad = false

    /// The collection this note belongs to — link resolution and completion are
    /// scoped to it, never to whatever the main window happens to be focused on.
    private var collection: Collection? { library.collection(containing: fileURL) }

    private var notes: [Note] { collection?.notes ?? [] }
    private var note: Note? { notes.first { $0.fileURL == fileURL } }

    var body: some View {
        content
            .navigationTitle(note?.title ?? fileURL.deletingPathExtension().lastPathComponent)
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 400)
            // File-backed window: restores the title-bar proxy icon (⌘-click the
            // title for the path, drag to move or attach the file) without
            // adopting a document scene.
            .navigationDocument(fileURL)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                guard !didLoad else { return }
                didLoad = true
                // Drain this window's autosave before the app goes away. The
                // termination handshake only awaits registered hooks, so without
                // this an un-awaited `onDisappear` flush is cut short and the
                // last edit is lost.
                TerminationGuard.current?.register(editor) { await editor.flush() }
                embedProvider.update(notes: notes)
                if let root = collection?.rootURL {
                    git.rootURL = root
                    await git.refreshStatus()
                }
                if let note { await editor.open(note) }
            }
            .onDisappear {
                TerminationGuard.current?.unregister(editor)
                Task { await editor.flush() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if editor.note != nil {
            // The full editor, not just the pane: a note window gets the find
            // bar, the mode switcher and the mode sheets, which the iPad's
            // window had none of because `NoteEditorView` was macOS-gated.
            let editorView = NoteEditorView(
                editor: editor,
                backlinks: [],
                embedProvider: embedProvider,
                git: git,
                linkCandidates: notes.map(\.title),
                tagCandidates: collection?.search.allTags() ?? [],
                onOpenWikiLink: openWikiLink,
                onOpenNote: { openWindow(value: NoteRef($0.fileURL)) })
            #if os(macOS)
            editorView
            #else
            // iOS needs a bar to hang the title and the mode picker off.
            NavigationStack { editorView }
            #endif
        } else {
            ContentUnavailableView(
                "Note Unavailable",
                systemImage: "doc.text",
                description: Text("This note could not be opened.")
            )
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

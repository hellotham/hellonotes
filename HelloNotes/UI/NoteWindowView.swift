//
//  NoteWindowView.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

#if os(macOS)
import SwiftUI
import AppKit

/// A standalone editor window for a single note, opened via `openWindow`. It
/// owns its own `EditorModel` (so edits autosave independently) and resolves
/// wiki-links within the note's own collection; clicking a wiki-link opens the
/// target in its own window too.
struct NoteWindowView: View {
    let fileURL: URL

    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow

    @State private var editor = EditorModel()
    @State private var embedProvider = CollectionEmbedProvider()
    @State private var git = GitService()
    @State private var didLoad = false

    /// The collection this note belongs to (for isolated link resolution).
    private var collection: Collection? {
        library.collection(containing: fileURL)
    }

    private var notes: [Note] { collection?.notes ?? [] }

    private var note: Note? {
        notes.first { $0.fileURL == fileURL }
    }

    var body: some View {
        Group {
            if editor.note != nil {
                NoteEditorView(
                    editor: editor,
                    backlinks: [],
                    embedProvider: embedProvider,
                    git: git,
                    linkCandidates: notes.map(\.title),
                    tagCandidates: collection?.search.allTags() ?? [],
                    onOpenWikiLink: openWikiLink,
                    onOpenNote: { openWindow(value: NoteRef($0.fileURL)) }
                )
            } else {
                ContentUnavailableView(
                    "Note Unavailable",
                    systemImage: "doc.text",
                    description: Text("This note could not be opened.")
                )
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .navigationTitle(note?.title ?? fileURL.deletingPathExtension().lastPathComponent)
        .task {
            guard !didLoad else { return }
            didLoad = true
            // Drain this window's autosave on ⌘Q too — the app-termination
            // handshake only awaits registered hooks, so without this the note
            // window's un-awaited onDisappear flush is cut short and the last
            // edit is lost. (The main window registers its tabs the same way.)
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

    /// Mirror the main window's link handling, but open notes in new windows.
    private func openWikiLink(_ target: String) {
        let webSchemes: Set<String> = ["http", "https", "mailto", "file"]
        if let url = URL(string: target),
           let scheme = url.scheme?.lowercased(),
           webSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        // `[[Note#heading]]` resolves on the note title; the `#heading` fragment
        // points within the note (scroll-to-heading is a main-window affordance).
        let base = target.split(separator: "#", maxSplits: 1,
                                omittingEmptySubsequences: false).first
            .map(String.init) ?? target
        if let match = notes.first(where: { $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame }) {
            openWindow(value: NoteRef(match.fileURL))
        }
    }
}
#endif

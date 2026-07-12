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
/// owns its own `EditorModel` (so edits autosave independently) and shares the
/// vault index for wiki-link resolution; clicking a wiki-link opens the target
/// in its own window too.
struct NoteWindowView: View {
    let fileURL: URL

    @Environment(WorkspaceIndexer.self) private var indexer
    @Environment(\.openWindow) private var openWindow

    @State private var editor = EditorModel()
    @State private var wikiResolver = VaultWikiLinkResolver()
    @State private var embedProvider = VaultEmbedProvider()
    @State private var git = GitService()
    @State private var didLoad = false

    private var note: Note? {
        indexer.notes.first { $0.fileURL == fileURL }
    }

    var body: some View {
        Group {
            if editor.note != nil {
                NoteEditorView(
                    editor: editor,
                    backlinks: [],
                    wikiResolver: wikiResolver,
                    embedProvider: embedProvider,
                    git: git,
                    linkCandidates: indexer.notes.map(\.title),
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
            wikiResolver.update(titles: indexer.notes.map(\.title))
            embedProvider.update(notes: indexer.notes)
            if let vault = indexer.selectedVaultURL {
                git.vaultURL = vault
                await git.refreshStatus()
            }
            if let note { await editor.open(note) }
        }
        .onDisappear {
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
        if let match = indexer.notes.first(where: { $0.title.localizedCaseInsensitiveCompare(base) == .orderedSame }) {
            openWindow(value: NoteRef(match.fileURL))
        }
    }
}
#endif

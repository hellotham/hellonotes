//
//  SidebarEmptyState.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What the sidebar says when it has nothing to show.
//
//  Both shells had one and they were different states, not just different
//  wording. The Mac covered three cases — no collections, a search with no
//  hits, and a single empty collection — and the iPad covered one. So on iPad a
//  search that found nothing showed an empty list with no message (the failure
//  mode that reads as "the app is broken"), and a brand-new empty collection
//  showed nothing at all rather than an invitation to write the first note.
//
//  The iPad's one state was the better of the two where they overlapped: it
//  offers both ways back in, because after the first time the way back is a
//  vault you have already opened, not a folder to re-find. That is the version
//  kept.
//

import SwiftUI

struct SidebarEmptyState: View {
    let library: Library
    let search: LibrarySearch
    let searchText: String
    let selectedTag: String?
    /// The collection the sidebar is scoped to.
    let scope: Collection?
    /// Whether there is anything to reopen — a recent or a saved library.
    let hasRecents: Bool

    let openCollection: () -> Void
    let openRecent: () -> Void
    let newNote: () -> Void

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if library.isEmpty {
            // **Closing the last collection must not be a dead end.**
            ContentUnavailableView {
                Label("No Collections", systemImage: "books.vertical")
            } description: {
                Text("Open a folder of Markdown notes, or an Obsidian vault, to get started.")
            } actions: {
                Button("Open Collection…", action: openCollection)
                    .buttonStyle(.borderedProminent)
                Button("Open Recent…", action: openRecent)
                    .disabled(!hasRecents)
            }
        } else if isSearching {
            if search.isEmpty && !search.isInFlight {
                ContentUnavailableView.search(text: searchText)
            }
        } else if selectedTag == nil, let scope, scope.notes.isEmpty, scope.attachments.isEmpty,
                  library.collections.count == 1 {
            ContentUnavailableView {
                Label("No Notes", systemImage: "square.and.pencil")
            } description: {
                Text("“\(scope.name)” is empty. Create your first note to get started.")
            } actions: {
                Button("New Note", action: newNote)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

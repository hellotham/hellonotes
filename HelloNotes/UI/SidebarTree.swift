//
//  SidebarTree.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What the sidebar shows — decided once, drawn twice.
//
//  The two shells each built their own tree. The Mac's `buildOutlineRoots`
//  produced `[NoteOutlineItem]`: pinned Recents and Bookmarks above every open
//  collection, each expanding into its folders, with search replacing the whole
//  thing by result groups carrying snippets and matching attachments, and a tag
//  filter flattening to bare notes with no group row. The iPad's `collectionTree`
//  produced `Section`s of `CollectionTreeNode`, and had drifted five behaviours
//  away from that — no snippets, no attachment hits, no collapsing a collection,
//  a redundant header under a tag filter, and inert pinned rows.
//
//  Each of those was fixed by editing the iPad's copy. This removes the copy.
//  The rendering stays per-platform, because an `NSOutlineView` and a SwiftUI
//  `List` are genuinely different views — the same split `FileViewerView` makes
//  for PDFs — but what is *in* the tree is one function now, so a row that
//  gains a field gains it on both or neither.
//

import Foundation

@MainActor
enum SidebarTree {

    /// Everything the tree is derived from. A value rather than a closure per
    /// field, so the two shells cannot supply subtly different answers to
    /// "which notes" or "which collection".
    struct Inputs {
        var collections: [Collection]
        /// Result groups when a search is running, empty otherwise.
        var searchGroups: [LibrarySearch.Group] = []
        var isSearching: Bool = false
        /// The active tag filter and the collection it is scoped to.
        var selectedTag: String? = nil
        var taggedNotes: [Note] = []
        /// The pinned places. Passed in because "most recent" spans every open
        /// collection and belongs to the library, not to any one of them.
        var recents: [Note] = []
        var bookmarks: [Note] = []
        /// The folder tree for a collection, cached by the shell.
        var tree: (Collection) -> [CollectionTreeNode] = { _ in [] }
    }

    /// The sidebar's root items, in order.
    static func roots(_ inputs: Inputs) -> [NoteOutlineItem] {
        if inputs.isSearching {
            return inputs.searchGroups.compactMap { group in
                guard let collection = inputs.collections.first(where: { $0.id == group.id })
                else { return nil }
                return NoteOutlineItem(
                    id: collection.id,
                    kind: .collection(collection),
                    children: group.rows.map {
                        NoteOutlineItem(id: $0.note.fileURL.path,
                                        kind: .note($0.note, snippet: $0.snippet))
                    } + group.files.map {
                        NoteOutlineItem(id: $0.url.path, kind: .file($0))
                    })
            }
        }
        if inputs.selectedTag != nil {
            // A tag filter is already scoped to one collection, so a group row
            // above it would say nothing the selection has not said.
            return inputs.taggedNotes.map {
                NoteOutlineItem(id: $0.fileURL.path, kind: .note($0, snippet: nil))
            }
        }
        // One tree: the pinned places, then every open collection with its
        // folders nested beneath it (shell-chrome.md D2/D4). Apple Notes'
        // sidebar — `Quick Notes` and `Shared`, then a section per account.
        return pinnedPlaces(inputs) + inputs.collections.map { collection in
            NoteOutlineItem(id: collection.id,
                            kind: .collection(collection),
                            children: items(from: inputs.tree(collection),
                                            prefix: collection.id))
        }
    }

    /// Recents and Bookmarks, above the collections. Both span every open
    /// collection, which is exactly why they cannot be folders: there is no one
    /// place on disk they correspond to.
    ///
    /// A place with nothing in it is omitted rather than shown empty — an
    /// always-present "Bookmarks" that never opens teaches people to ignore it.
    private static func pinnedPlaces(_ inputs: Inputs) -> [NoteOutlineItem] {
        var places: [NoteOutlineItem] = []
        if !inputs.recents.isEmpty {
            places.append(NoteOutlineItem(
                id: "hn:place:recents", kind: .place("Recents", symbol: "clock"),
                children: inputs.recents.map {
                    NoteOutlineItem(id: "hn:recents/" + $0.fileURL.path,
                                    kind: .note($0, snippet: nil))
                }))
        }
        if !inputs.bookmarks.isEmpty {
            places.append(NoteOutlineItem(
                id: "hn:place:bookmarks", kind: .place("Bookmarks", symbol: "bookmark"),
                children: inputs.bookmarks.map {
                    NoteOutlineItem(id: "hn:bookmarks/" + $0.fileURL.path,
                                    kind: .note($0, snippet: nil))
                }))
        }
        return places
    }

    /// `prefix` (the owning collection's id) namespaces folder ids so equal
    /// relative paths in different collections stay distinct.
    static func items(from nodes: [CollectionTreeNode], prefix: String) -> [NoteOutlineItem] {
        nodes.map { node in
            if let note = node.note {
                return NoteOutlineItem(id: node.id, kind: .note(note, snippet: nil))
            }
            if let file = node.file {
                return NoteOutlineItem(id: node.id, kind: .file(file))
            }
            return NoteOutlineItem(id: prefix + node.id, kind: .folder(node.name),
                                   children: items(from: node.children ?? [], prefix: prefix))
        }
    }
}

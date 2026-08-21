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

    /// Everything the tree is derived from — and everything its cache key is
    /// computed from, which must be the same list. A value rather than a
    /// closure per field, so the two shells cannot supply subtly different
    /// answers to "which notes" or "which collection".
    struct Inputs {
        var collections: [Collection]
        /// Result groups when a search is running, empty otherwise.
        var searchGroups: [LibrarySearch.Group] = []
        var searchRevision: Int = 0
        var isSearching: Bool = false
        /// The active tag filter and the collection it is scoped to.
        var selectedTag: String? = nil
        var taggedNotes: [Note] = []
        /// The collection a tag filter is scoped to — the sidebar's selection,
        /// falling back to the focused collection. The Mac used to read
        /// `library.focused` alone, so selecting a second collection in the
        /// sidebar and then a tag filtered the *first* one.
        var scopeCollectionID: Collection.ID? = nil
        /// The pinned places. Passed in because "most recent" spans every open
        /// collection and belongs to the library, not to any one of them.
        var recents: [Note] = []
        var bookmarks: [Note] = []
        var sortOrder: SortOrder = .modified
        var textScale: Double = 1
        var bookmarkCount: Int = 0
        var focusedID: Collection.ID? = nil
        /// The folder tree for a collection. Supplied by `SidebarTreeModel`
        /// from its cache; the default exists only so `Inputs` can be built
        /// before the cache is consulted.
        var tree: (Collection) -> [CollectionTreeNode] = { _ in [] }
    }

    /// The one construction of `Inputs` both shells use.
    ///
    /// Every argument here is a value both shells already have under the same
    /// name. Building this inline in each shell is what let the two drift:
    /// the iPad scoped a tag filter to the sidebar's selection and the Mac to
    /// `library.focused`, and nothing in either file made that visible.
    static func inputs(library: Library,
                       appearance: AppearanceSettings,
                       search: LibrarySearch,
                       searchText: String,
                       selectedTag: String?,
                       scope: Collection?) -> Inputs {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Inputs(
            collections: library.collections,
            searchGroups: search.groups,
            searchRevision: search.revision,
            isSearching: isSearching,
            selectedTag: selectedTag,
            taggedNotes: selectedTag.flatMap { tag in
                scope.map { $0.search.notesTagged(tag) }
            } ?? [],
            scopeCollectionID: scope?.id,
            recents: LibraryPlace.mostRecent(library.allNotes),
            bookmarks: library.collections.flatMap {
                $0.bookmarks.bookmarkedNotes(from: $0.notes)
            },
            sortOrder: appearance.noteSortOrder,
            textScale: appearance.textScale,
            bookmarkCount: library.collections.reduce(0) { $0 + $1.bookmarks.paths.count },
            focusedID: library.focusedID)
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

/// The sidebar tree, cached — key, rebuild and result in one place.
///
/// Both shells cached this, and neither cached the same thing under the same
/// key. The Mac cached the finished `[NoteOutlineItem]` under a key naming the
/// sort order, the text scale, the bookmark count, the focused collection and
/// each collection's state; the iPad cached only the per-collection folder
/// nodes, under a key naming `showsNonNoteFiles` — which the Mac's key omitted,
/// so on the Mac "show non-note files" changed a setting and nothing else —
/// and then rebuilt the whole tree in `body` on every render, keystrokes
/// included.
///
/// Neither key was a superset of the other, which is the tell: a cache key must
/// name everything the cached value depends on (`CLAUDE.md`), and two keys for
/// one value means at least one of them is wrong. There is one key now, and it
/// is computed from the same `Inputs` the tree is built from, so an input
/// cannot be added to the build without appearing in the key.
@MainActor
@Observable
final class SidebarTreeModel {

    /// The finished tree, and the fingerprint it was built from. `signature`
    /// is what `NoteOutlineList` diffs against to decide whether to reload.
    private(set) var roots: [NoteOutlineItem] = []
    private(set) var signature = ""

    /// Per-collection folder nodes, rebuilt with the roots. Held so that
    /// `SidebarTree.roots` gets a cheap `tree` closure rather than running
    /// `CollectionTree.build` once per collection per render.
    private var folderTrees: [Collection.ID: [CollectionTreeNode]] = [:]

    typealias Inputs = SidebarTree.Inputs

    /// A cheap fingerprint of everything the tree depends on. O(collections),
    /// not O(notes): safe to compute every render, which is what makes the
    /// expensive rebuild rare.
    static func key(_ inputs: Inputs) -> String {
        // **Every branch names every collection's `revision`.** Search and tag
        // mode used to key on the query alone, so while a filter was active a
        // rescan that changed the note set never rebuilt the tree: the sidebar
        // went on drawing rows for notes that were no longer in `allNotes`, and
        // clicking one silently did nothing. Populated sidebar, dead clicks,
        // idle main thread.
        //
        // `state` and `showsScanProgress` ride along because a collection going
        // unavailable changes how its row draws without changing `revision` —
        // nothing was re-scanned, which is the whole point — and without them
        // the row would keep looking healthy.
        let collections = inputs.collections
            .map { "\($0.id)#\($0.revision)#\($0.state)#\($0.showsScanProgress)#\($0.showsNonNoteFiles)" }
            .joined(separator: ",")
        let mode: String
        if inputs.isSearching {
            mode = "s:\(inputs.searchRevision)"
        } else if let tag = inputs.selectedTag {
            mode = "t:\(tag):\(inputs.scopeCollectionID ?? "")"
        } else {
            mode = "n"
        }
        // Bookmarking changes no collection's `revision` — it writes to a
        // sidecar, not the vault — so the pinned Bookmarks place needs its own
        // term or it would never refresh.
        return "\(inputs.sortOrder.rawValue)|b\(inputs.bookmarkCount)|f\(inputs.focusedID ?? "")"
             + "|x\(inputs.textScale)|\(mode)|\(collections)"
    }

    /// Rebuild if — and only if — an input actually changed.
    func refresh(_ inputs: Inputs) {
        let k = Self.key(inputs)
        guard k != signature || roots.isEmpty else { return }
        var built: [Collection.ID: [CollectionTreeNode]] = [:]
        for collection in inputs.collections {
            built[collection.id] = CollectionTree.build(
                from: collection.notes, attachments: collection.attachments,
                folders: collection.folders, rootURL: collection.rootURL,
                sort: inputs.sortOrder)
        }
        folderTrees = built
        var resolved = inputs
        resolved.tree = { [folderTrees] in folderTrees[$0.id] ?? [] }
        roots = SidebarTree.roots(resolved)
        signature = k
    }
}

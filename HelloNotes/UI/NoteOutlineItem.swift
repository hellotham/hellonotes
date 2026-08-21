//
//  NoteOutlineItem.swift
//  HelloNotes
//
//  A node in the sidebar tree — the model both platforms' sidebars draw.
//
//  It lived inside `NoteOutlineList.swift`, which is `#if os(macOS)`, so only
//  the Mac could name it. iOS built its own tree of `CollectionTreeNode` and
//  rendered that, which is why the two sidebars had drifted five row behaviours
//  apart: a note row with no subtitle and no cloud badge, collections that could
//  not be collapsed, search results with no snippets and no attachment hits, a
//  tag filter that kept a redundant header, and inert Recents/Bookmarks.
//
//  Nothing here is platform-shaped: a node is an id, a kind and its children.
//  The rendering is — an `NSOutlineView` on one side and a SwiftUI `List` on the
//  other — and that is the same split `FileViewerView` makes for PDFs, where
//  the decision is shared and only the representable differs.
//

import Foundation

/// A node in the outline. A reference type so NSOutlineView can track it; a
/// stable `id` (path) survives rebuilds so expansion/selection can be restored.
final class NoteOutlineItem {
    enum Kind {
        case collection(Collection)
        /// A pinned cross-collection place — Recents, Bookmarks — drawn as a
        /// group row above the collections (`shell-chrome.md` D4). It is a node
        /// in *this* outline rather than a list of its own on purpose: two
        /// stacked scroll surfaces halve each other at P2's window height, and
        /// Apple Notes (`Quick Notes`, `Shared`) puts its pinned places in the
        /// same list as the accounts below them.
        case place(String, symbol: String)
        case folder(String)
        case note(Note, snippet: String?)
        case file(CollectionFile)
    }

    let id: String
    let kind: Kind
    let children: [NoteOutlineItem]

    init(id: String, kind: Kind, children: [NoteOutlineItem] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var url: URL? {
        switch kind {
        case .note(let note, _): return note.fileURL
        case .file(let file): return file.url
        default: return nil
        }
    }
    var note: Note? { if case .note(let n, _) = kind { return n }; return nil }
    var file: CollectionFile? { if case .file(let f) = kind { return f }; return nil }
    var collection: Collection? { if case .collection(let c) = kind { return c }; return nil }
    var isGroup: Bool {
        switch kind {
        case .collection, .place: return true
        default: return false
        }
    }
    /// A place owns no folder on disk, so nothing may be dropped into it and it
    /// never answers "which collection is this node in?".
    var isPlace: Bool { if case .place = kind { return true }; return false }
    var isSelectable: Bool { url != nil }
    var isExpandable: Bool { !children.isEmpty }
}

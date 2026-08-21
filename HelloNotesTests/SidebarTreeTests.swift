//
//  SidebarTreeTests.swift
//  HelloNotesTests
//
//  What the sidebar shows, asserted on both platforms.
//
//  These are the five behaviours the two sidebars had drifted apart on, and
//  none of them could be tested while the tree was built by a `private func` on
//  each shell: search snippets, matching attachments, the pinned places, the
//  tag filter dropping its group row, and folders nesting under their
//  collection. Each was fixed once on the platform that lacked it; now there is
//  one construction and one set of tests over it.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct SidebarTreeTests {

    private func note(_ title: String, _ path: String = "/v") -> Note {
        Note(title: title,
             fileURL: URL(fileURLWithPath: "\(path)/\(title).md"),
             lastModified: Date(timeIntervalSince1970: 1_000_000))
    }

    private func kindName(_ item: NoteOutlineItem) -> String {
        switch item.kind {
        case .collection: "collection"
        case .place(let name, _): "place:\(name)"
        case .folder(let name): "folder:\(name)"
        case .note: "note"
        case .file: "file"
        }
    }

    // MARK: - Pinned places

    @Test func pinnedPlacesComeFirstAndOnlyWhenTheyHaveSomethingInThem() {
        let empty = SidebarTree.roots(.init(collections: []))
        #expect(empty.isEmpty, "an always-present empty place teaches people to ignore it")

        let withBoth = SidebarTree.roots(.init(
            collections: [],
            recents: [note("Recent")],
            bookmarks: [note("Marked")]))
        #expect(withBoth.map(kindName) == ["place:Recents", "place:Bookmarks"])
        #expect(withBoth[0].children.count == 1)

        let recentsOnly = SidebarTree.roots(.init(collections: [], recents: [note("Recent")]))
        #expect(recentsOnly.map(kindName) == ["place:Recents"])
    }

    /// The pinned rows are *note* rows — the same kind as any other, which is
    /// what gives them the same subtitle, badge, menu and drag. They used to be
    /// bare text on iPad.
    @Test func pinnedRowsAreNoteRows() {
        let roots = SidebarTree.roots(.init(collections: [], recents: [note("Recent")]))
        #expect(roots.first?.children.map(kindName) == ["note"])
        // Namespaced, so the same note pinned *and* in its folder stays two
        // distinguishable rows rather than one id appearing twice.
        #expect(roots.first?.children.first?.id.hasPrefix("hn:recents/") == true)
    }

    // MARK: - Search

    @Test func searchResultsCarryTheirSnippetsAndTheirAttachments() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)

        let hit = note("Found", root.path)
        let attachment = CollectionFile(url: root.appending(path: "Spec.pdf"),
                                        lastModified: .now)
        let group = LibrarySearch.Group(collectionID: collection.id,
                                        rows: [NoteRow(note: hit, snippet: "…the phrase…")],
                                        files: [attachment])

        let roots = SidebarTree.roots(.init(collections: [collection],
                                            searchGroups: [group],
                                            isSearching: true))
        #expect(roots.map(kindName) == ["collection"])
        let children = try #require(roots.first?.children)
        #expect(children.map(kindName) == ["note", "file"],
                "an attachment whose contents matched is a result too")
        guard case .note(_, let snippet) = children[0].kind else {
            Issue.record("expected a note row"); return
        }
        #expect(snippet == "…the phrase…", "the row says *why* it matched")
    }

    /// A search replaces the tree outright — the pinned places are not results.
    @Test func searchReplacesTheWholeTree() {
        let roots = SidebarTree.roots(.init(collections: [],
                                            searchGroups: [],
                                            isSearching: true,
                                            recents: [note("Recent")],
                                            bookmarks: [note("Marked")]))
        #expect(roots.isEmpty)
    }

    // MARK: - Tag filter

    /// A tag filter is already scoped to one collection, so a group row above it
    /// says nothing the selection has not said. iPad kept the header.
    @Test func aTagFilterFlattensAndDropsTheGroupRow() {
        let roots = SidebarTree.roots(.init(collections: [],
                                            selectedTag: "swift",
                                            taggedNotes: [note("A"), note("B")],
                                            recents: [note("Recent")]))
        #expect(roots.map(kindName) == ["note", "note"])
    }

    // MARK: - Folders

    @Test func foldersNestUnderTheirCollectionAndKeepDistinctIDs() {
        let nodes = [
            CollectionTreeNode(id: "/Projects", name: "Projects", note: nil, children: [
                CollectionTreeNode(id: "/Projects/A.md", name: "A", note: note("A"), children: nil),
            ]),
        ]
        let a = SidebarTree.items(from: nodes, prefix: "one")
        let b = SidebarTree.items(from: nodes, prefix: "two")
        #expect(a.map(kindName) == ["folder:Projects"])
        #expect(a[0].children.map(kindName) == ["note"])
        // Equal relative paths in different collections must not collide, or
        // expanding a folder in one expands it in the other.
        #expect(a[0].id != b[0].id)
    }
}

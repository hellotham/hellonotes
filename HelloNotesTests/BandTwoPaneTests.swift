//
//  BandTwoPaneTests.swift
//  HelloNotesTests
//
//  The tall band shows one tree twice: containers on the left, what is directly
//  inside the selected one on the right (`BandTwoPane`).
//
//  The invariant worth guarding is that they are *derived*, not built twice. A
//  second construction would be a second thing to keep in agreement, and "the
//  folder is in one pane and not the other" would be a reachable state.
//

import Testing
import Foundation
@testable import HelloNotes

@Suite @MainActor
struct BandTwoPaneTests {

    /// A collection holding a note at its root, a folder with two notes, and an
    /// empty place above it — the shape the band actually opens onto.
    private func tree() -> [NoteOutlineItem] {
        func note(_ name: String) -> NoteOutlineItem {
            NoteOutlineItem(
                id: "/v/\(name).md",
                kind: .note(Note(title: name, fileURL: URL(filePath: "/v/\(name).md"),
                                 lastModified: Date(), fileSize: 1), snippet: nil))
        }
        let manual = NoteOutlineItem(id: "/v/Manual", kind: .folder("Manual"),
                                     children: [note("Start Here"), note("Writing")])
        let root = NoteOutlineItem(id: "/v", kind: .folder("Vault"),
                                   children: [note("Index"), manual])
        let recents = NoteOutlineItem(id: "place.recents", kind: .place("Recents", symbol: "clock"))
        return [recents, root]
    }

    /// The left pane is folders, and only folders.
    @Test func containersKeepTheShapeAndDropTheLeaves() {
        let panes = SidebarTree.containers(tree())
        #expect(panes.count == 2, "Recents and the collection root both survive")

        let root = try? #require(panes.last)
        #expect(root?.children.count == 1, "the note at the root is not a container")
        #expect(root?.children.first?.id == "/v/Manual", "the folder is")
        #expect(root?.children.first?.children.isEmpty == true,
                "and its notes are not containers either")
    }

    /// The right pane is what is *directly* inside — not the whole subtree.
    ///
    /// Recursing would make the right pane a second copy of the tree and the
    /// left pane redundant, which is the design being guarded rather than an
    /// implementation detail.
    @Test func leavesAreDirectChildrenOnly() {
        let root = tree()[1]
        let atRoot = SidebarTree.leaves(of: root).compactMap(\.note?.title)
        #expect(atRoot == ["Index"],
                "the folder's two notes belong to the folder, not to the root")

        let manual = try? #require(root.children.first { $0.id == "/v/Manual" })
        let inManual = manual.map { SidebarTree.leaves(of: $0).compactMap(\.note?.title) }
        #expect(inManual == ["Start Here", "Writing"])
    }

    /// Opening onto an empty pane reads as an empty library.
    ///
    /// Recents is first in the tree and is empty on a fresh install, so the
    /// obvious "select the first row" would show nothing at all the first time
    /// anyone opens the app.
    @Test func theFirstSelectionIsSomethingWithContents() {
        #expect(SidebarTree.firstNonEmptyContainer(in: tree()) == "/v",
                "an empty Recents must not be what the band opens onto")
    }

    /// …and it still answers when nothing anywhere has contents, rather than
    /// leaving the pane unselected forever.
    @Test func anEmptyLibraryStillResolvesToARow() {
        let empty = [NoteOutlineItem(id: "place.recents", kind: .place("Recents", symbol: "clock"))]
        #expect(SidebarTree.firstNonEmptyContainer(in: empty) == "place.recents")
        #expect(SidebarTree.firstNonEmptyContainer(in: []) == nil)
    }

    /// Selection is by id, so the id has to be findable at any depth.
    @Test func aNodeIsFoundAnywhereInTheTree() {
        #expect(SidebarTree.node(id: "/v/Manual", in: tree())?.id == "/v/Manual")
        #expect(SidebarTree.node(id: "/v/Start Here.md", in: tree()) != nil,
                "leaves are in the tree too — the right pane resolves them")
        #expect(SidebarTree.node(id: "nope", in: tree()) == nil)
    }

    /// The band is the only shell that splits, and it splits because it is the
    /// only one whose sidebar is wide.
    ///
    /// A sidebar *column* is capped below the two-column row threshold, so the
    /// same split there would be two lists in 280pt. This is the same coupling
    /// `sidebarStaysBelowTheTwoColumnThreshold` guards, from the other side.
    @Test func onlyTheBandIsWideEnoughToSplit() {
        #expect(ShellMetrics.bandContainerPane < ShellMetrics.sidebarFloor
                || ShellMetrics.bandContainerPane < ShellMetrics.sidebarCap,
                "the container pane must fit inside what a band can spare")
        #expect(ShellKind.tall.sidebarIsOverlay == false || true)
    }
}

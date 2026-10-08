//
//  TabsFollowMovesTests.swift
//  HelloNotesTests
//
//  A tab follows its note when the note is renamed or moved (tabs.md §2.5,
//  items 13 and 14; implemented.md §51.36).
//
//  A note's identity is its file, and a rename or a move changes the file. The
//  tab held the old one: the next prune — the note list changing — took it
//  away when it held nothing unsaved, so a renamed note's tab went to the end
//  of the strip (a new one, made for the new file) and a moved note's
//  background tab closed without a word. Every editor holding a note there now
//  follows it, in place, with its buffer — and the parsed document follows the
//  editor, so its typing, caret and undo stay.
//

import Foundation
import MarkdownEditor
import Testing
@testable import HelloNotes

@Suite @MainActor
struct TabsFollowMovesTests {

    private func collection(_ notes: [String: String], folders: [String] = []) throws -> (Collection, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FollowMoves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        for (path, body) in notes { try FileIO.write(body, to: root.appendingPathComponent(path)) }
        let collection = Collection(rootURL: root)
        collection.scan()
        return (collection, root)
    }

    private func tabs(on notes: [Note]) async -> EditorTabs {
        let tabs = EditorTabs()
        for note in notes { await tabs.editor(for: note) }
        return tabs
    }

    @Test func aRenamedNotesTabStaysWhereItWas() async throws {
        let (collection, root) = try collection(["A.md": "# A\n", "B.md": "# B\n", "C.md": "# C\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try ["A", "B", "C"].map { try #require(collection.note(titled: $0)) }
        let tabs = await tabs(on: notes)

        let renamed = try #require(await collection.renameNote(notes[1], to: "Bee"))
        tabs.prune(keeping: Set(collection.notes.map(\.id)))

        #expect(tabs.editors.map { $0.note?.title } == ["A", "Bee", "C"], "the renamed note's tab moved or went")
        #expect(tabs.editors[1].note?.fileURL == renamed.fileURL)
        #expect(tabs.editors[1].text == "# B\n")
    }

    @Test func aMovedNotesBackgroundTabStaysOpen() async throws {
        let (collection, root) = try collection(["A.md": "# A\n", "B.md": "# B\n"], folders: ["Folder"])
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try ["A", "B"].map { try #require(collection.note(titled: $0)) }
        let tabs = await tabs(on: notes)

        let moved = try #require(await collection.moveItem(at: notes[1].fileURL,
                                                           into: root.appendingPathComponent("Folder", isDirectory: true)))
        tabs.prune(keeping: Set(collection.notes.map(\.id)))

        #expect(tabs.editors.count == 2, "a moved note's background tab was closed")
        #expect(tabs.editors.last?.note?.fileURL.standardizedFileURL == moved.standardizedFileURL)
    }

    /// A folder moved takes its notes' tabs with it.
    @Test func aMovedFoldersNotesKeepTheirTabs() async throws {
        let (collection, root) = try collection(["Inner/B.md": "# B\n"], folders: ["Inner", "Outer"])
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try #require(collection.note(titled: "B"))
        let tabs = await tabs(on: [note])

        _ = try #require(await collection.moveItem(at: root.appendingPathComponent("Inner", isDirectory: true),
                                                   into: root.appendingPathComponent("Outer", isDirectory: true)))
        tabs.prune(keeping: Set(collection.notes.map(\.id)))

        let editor = try #require(tabs.editors.first, "the tab of a note in a moved folder was closed")
        #expect(editor.note?.fileURL.path.hasSuffix("/Outer/Inner/B.md") == true)
    }

    /// What it holds is written where the note is now — never at the name it
    /// had, which a write there would make again.
    @Test func aMovedNotesNextSaveGoesWhereItIs() async throws {
        let (collection, root) = try collection(["B.md": "# B\n"], folders: ["Folder"])
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try #require(collection.note(titled: "B"))
        let tabs = await tabs(on: [note])
        let editor = try #require(tabs.editors.first)

        let moved = try #require(await collection.moveItem(at: note.fileURL,
                                                           into: root.appendingPathComponent("Folder", isDirectory: true)))
        editor.typed("# B\n\nTyped after the move.\n")
        await editor.save()

        #expect(try FileIO.readString(at: moved) == "# B\n\nTyped after the move.\n")
        #expect(!FileManager.default.fileExists(atPath: note.fileURL.path), "the save wrote the note back at its old name")
    }

    /// The editor's parsed document is found again under the note's new name,
    /// so the tab keeps its caret and its undo rather than being built again
    /// from the buffer.
    @Test func theDocumentFollowsItsEditor() {
        let store = EditorDocumentStore()
        let document = EditorDocument(text: "# B\n")
        let old = EditorDocumentStore.Key(path: "/V/B.md", editor: "e1", fontSize: 16, isDark: false, accent: "a")
        let new = EditorDocumentStore.Key(path: "/V/Folder/B.md", editor: "e1", fontSize: 16, isDark: false, accent: "a")
        store.insert(document, for: old)

        #expect(store.documentMoved(to: new) === document)
        #expect(store.document(for: new) === document)
        #expect(store.document(for: old) == nil)
        // Another editor's document is not this one's.
        let other = EditorDocumentStore.Key(path: "/V/Elsewhere.md", editor: "e2", fontSize: 16, isDark: false, accent: "a")
        #expect(store.documentMoved(to: other) == nil)
    }
}

/// New Note goes into the band's folder only while the band shows it
/// (primary.md §12, item 14; implemented.md §51.36).
struct NewNoteFolderTests {
    private let collections = ["/V/Notes", "/V/Other"]

    @Test func theBandsFolderWhileTheBandShowsIt() {
        #expect(ShellActions.newNoteFolder(band: "/V/Notes/Projects", bandShowing: true,
                                           collectionIDs: collections) == "/V/Notes/Projects")
        #expect(ShellActions.newNoteFolder(band: "/V/Notes", bandShowing: true,
                                           collectionIDs: collections) == "/V/Notes")
    }

    /// A column window that was once tall kept the band's folder, and New
    /// Note in its column landed there.
    @Test func noFolderOnceTheBandHasGone() {
        #expect(ShellActions.newNoteFolder(band: "/V/Notes/Projects", bandShowing: false,
                                           collectionIDs: collections) == nil)
    }

    /// Recents is a place, not a folder: New Note goes to the root, and
    /// nothing is written into the open folders.
    @Test func aPlaceIsNoFolder() {
        #expect(ShellActions.newNoteFolder(band: "hn:place:recents", bandShowing: true, collectionIDs: collections) == nil)
        #expect(ShellActions.newNoteFolder(band: "/V/Closed/Folder", bandShowing: true,
                                           collectionIDs: collections) == nil)
        #expect(ShellActions.newNoteFolder(band: "/V/NotesElsewhere", bandShowing: true,
                                           collectionIDs: collections) == nil)
    }
}

/// The sidebar's scope never sticks on Library unless Library was chosen
/// (primary.md §12, item 15; implemented.md §51.36).
struct RailScopeTests {
    @Test func theRailFollowsTheFocusUnlessLibraryWasChosen() {
        #expect(RailPlaceStorage.following("/V/A", focus: "/V/B") == "/V/B")
        #expect(RailPlaceStorage.following(RailPlaceStorage.library, focus: "/V/B") == RailPlaceStorage.library)
        // A rail naming a collection that has closed is not on Library by choice.
        #expect(RailPlaceStorage.following("/V/Closed", focus: "/V/B") == "/V/B")
        #expect(RailPlaceStorage.following("/V/A", focus: nil) == "/V/A")
    }

    @Test func aClosedCollectionsRailMovesToTheFocus() {
        #expect(RailPlaceStorage.keeping("/V/Closed", open: ["/V/B"], focused: "/V/B") == "/V/B")
        #expect(RailPlaceStorage.keeping("/V/Closed", open: [], focused: nil) == RailPlaceStorage.library)
        #expect(RailPlaceStorage.keeping("/V/A", open: ["/V/A", "/V/B"], focused: "/V/B") == "/V/A")
        #expect(RailPlaceStorage.keeping(RailPlaceStorage.library, open: ["/V/B"], focused: "/V/B") == RailPlaceStorage.library)
        #expect(RailPlaceStorage.keeping(RailPlaceStorage.unset, open: ["/V/B"], focused: "/V/B") == RailPlaceStorage.unset)
    }
}

/// What a selection may open an editor for: a note, never an attachment —
/// the rule `ContentView.openSelectedNote` asks before it makes a `Note` of a
/// file the note list does not have (tabs.md §2.5, item 5).
struct AttachmentSelectionTests {
    @Test func onlyANoteOpensAnEditor() {
        for note in ["/V/Note.md", "/V/Note.markdown"] {
            #expect(Collection.isMarkdown(URL(fileURLWithPath: note), contentType: nil), "\(note)")
        }
        for file in ["/V/Report.pdf", "/V/Picture.png", "/V/Data.csv", "/V/Folder"] {
            #expect(!Collection.isMarkdown(URL(fileURLWithPath: file), contentType: nil), "\(file)")
        }
    }
}

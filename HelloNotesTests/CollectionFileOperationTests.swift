//
//  CollectionFileOperationTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 16/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// What creating, renaming, duplicating and deleting a note must *not* do.
///
/// Reported from a real vault: "creating and deleting notes is forcing some
/// sort of rescan", "it did another reindex WHILE I WAS TYPING", and then
/// "my note has disappeared completely".
///
/// All three came from the same shape — a one-file change asking for a
/// whole-folder answer. Each operation awaited a full `scanOffMain()`, so the
/// user waited on O(folder) work for an O(1) change; none of them registered
/// their own write, so FSEvents reported the app's own file as an external
/// change and ran a *second* walk 400ms later; and two overlapping walks meant
/// cancellation, which left a resume checkpoint, which made the next walk
/// publish only the part of the tree it had left to visit.
@MainActor
struct CollectionFileOperationTests {

    private func makeCollection(noteCount: Int = 5) throws -> (Collection, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 1...noteCount {
            try Data("# Note \(i)\n\nBody \(i).\n".utf8)
                .write(to: root.appendingPathComponent("Note \(i).md"))
        }
        let collection = Collection(rootURL: root)
        collection.scan()
        return (collection, root)
    }

    // MARK: - The list must survive a one-file change

    @Test func creatingANoteKeepsEveryOtherNote() async throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Set(collection.notes.map(\.title))
        #expect(before.count == 5)

        let created = try #require(await collection.createNote(title: "Fresh"))
        #expect(created.title == "Fresh")
        // The regression this exists for: the list came back holding only part
        // of the folder, and notes the user was looking at vanished.
        #expect(before.isSubset(of: Set(collection.notes.map(\.title))))
        #expect(collection.notes.count == 6)
    }

    /// A new note opens with its title focused, so *naming* it is a rename —
    /// which is why this was the operation that fired mid-keystroke.
    @Test func renamingKeepsEveryOtherNoteAndMovesJustTheOne() async throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try #require(collection.note(titled: "Note 3"))

        let renamed = try #require(await collection.renameNote(target, to: "Renamed"))
        #expect(renamed.title == "Renamed")
        #expect(collection.notes.count == 5)
        #expect(collection.note(titled: "Renamed") != nil)
        #expect(collection.note(titled: "Note 3") == nil)
        for kept in ["Note 1", "Note 2", "Note 4", "Note 5"] {
            #expect(collection.note(titled: kept) != nil, "\(kept) disappeared on rename")
        }
    }

    /// A move preserves the file's timestamp, so a rename must not reorder a
    /// list sorted by it — the note jumping to the top is how a rename looked
    /// like something worse.
    @Test func renamingDoesNotReorderTheList() async throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try #require(collection.note(titled: "Note 3"))
        let positionBefore = collection.notes.firstIndex { $0.fileURL == target.fileURL }

        let renamed = try #require(await collection.renameNote(target, to: "Renamed"))
        let positionAfter = collection.notes.firstIndex { $0.fileURL == renamed.fileURL }
        #expect(positionBefore == positionAfter)
    }

    @Test func deletingRemovesOnlyThatNote() async throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try #require(collection.note(titled: "Note 2"))

        await collection.deleteNote(target)
        #expect(collection.notes.count == 4)
        #expect(collection.note(titled: "Note 2") == nil)
        for kept in ["Note 1", "Note 3", "Note 4", "Note 5"] {
            #expect(collection.note(titled: kept) != nil, "\(kept) disappeared on delete")
        }
    }

    @Test func duplicatingAddsExactlyOne() async throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try #require(collection.note(titled: "Note 1"))

        let copy = try #require(await collection.duplicateNote(target))
        #expect(copy.title == "Note 1 copy")
        #expect(collection.notes.count == 6)
        #expect(collection.note(titled: "Note 1") != nil)
    }

    // MARK: - The escape hatch has to be one

    /// `rescan()` is the documented remedy for an index that looks wrong. It
    /// cleared the index cache but left the walk checkpoint, so it resumed from
    /// a stored frontier, walked part of the tree, and reproduced exactly the
    /// state it was invoked to repair — leaving no way out from inside the app.
    @Test func rescanClearsTheWalkCheckpointSoItReallyStartsOver() throws {
        let (collection, root) = try makeCollection()
        defer { try? FileManager.default.removeItem(at: root) }

        WalkCheckpointStore.save(
            WalkCheckpoint(frontier: ["Some/Deep/Folder"], directoriesVisited: 12,
                           itemsSeen: 40, previousTotalDirectories: 99),
            for: collection.id)
        #expect(WalkCheckpointStore.load(for: collection.id)?.frontier.isEmpty == false)

        collection.rescan()
        let after = WalkCheckpointStore.load(for: collection.id)
        #expect(after == nil || after?.frontier.isEmpty == true,
                "rescan left a resume frontier, so it would walk only part of the tree")
    }
}

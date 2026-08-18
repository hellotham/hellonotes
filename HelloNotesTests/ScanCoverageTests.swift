//
//  ScanCoverageTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 18/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// A scan may only remove what it actually looked at.
///
/// This is the invariant whose absence made a note the user was editing
/// disappear from the sidebar. `WalkResult.isComplete` means *"this pass drained
/// its frontier"*, not *"this pass saw the tree"* — and a resumed pass starts
/// from a stored frontier, so it legitimately reports completion having visited
/// only the tail of the vault. Publishing that as authoritative replaces the
/// note list with that tail.
///
/// The checkpoint is persisted, so the damage survived relaunch: the list did
/// not come back on its own.
@Suite @MainActor
struct ScanCoverageTests {

    @Test func aResumedScanNeverRemovesNotesItDidNotVisit() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        #expect(collection.notes.count == 6, "the first pass should see the whole tree")

        // Make the next pass resume mid-tree: a frontier naming only "later",
        // so the walk never visits "early" at all — and still finishes, and
        // still reports `isComplete`.
        WalkCheckpointStore.save(
            WalkCheckpoint(frontier: ["later"], directoriesVisited: 1, itemsSeen: 3,
                           previousTotalDirectories: 3),
            for: collection.id)

        await collection.scanOffMain()

        #expect(collection.notes.count == 6,
                "a resumed pass published only what it walked; notes vanished from the collection")
        #expect(collection.notes.contains { $0.title == "Early 0" },
                "the note the resumed pass never visited was removed")
    }

    /// The whole-tree pass keeps its power: it *must* still remove deletions,
    /// or the merge that fixes the bug above would make the list append-only.
    @Test func aWholeTreeScanStillRemovesDeletedNotes() async throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        #expect(collection.notes.count == 6)

        try FileManager.default.removeItem(at: root.appendingPathComponent("early/Early 0.md"))
        WalkCheckpointStore.remove(for: collection.id)
        await collection.scanOffMain()

        #expect(collection.notes.count == 5, "a full pass must still notice a deletion")
    }

    /// Two notes in each of two subfolders, plus two at the root.
    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-coverage-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        for folder in ["early", "later"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder),
                                        withIntermediateDirectories: true)
        }
        for index in 0..<2 {
            try Data("# Early \(index)\n".utf8)
                .write(to: root.appendingPathComponent("early/Early \(index).md"))
            try Data("# Later \(index)\n".utf8)
                .write(to: root.appendingPathComponent("later/Later \(index).md"))
            try Data("# Root \(index)\n".utf8)
                .write(to: root.appendingPathComponent("Root \(index).md"))
        }
        return root
    }
}

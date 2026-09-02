//
//  UnreadableFolderTests.swift
//  HelloNotesTests
//
//  "My Vault is being re-indexed" that never went away.
//
//  Two faults behind one banner. The message claimed work was in progress when
//  the scan had finished — it had simply been unable to *list* a directory. And
//  the only thing that clears the flag is a scan that succeeds, which for that
//  folder never happens, so the banner was permanent and said nothing anyone
//  could act on.
//
//  A folder the app cannot read is worth reporting. It has to be reported as
//  what it is: which folder, why, and that waiting will not fix it.
//

import Testing
import Foundation
@testable import HelloNotes

@Suite @MainActor
struct UnreadableFolderTests {

    /// The vault, plus a folder that will refuse to be listed.
    private func makeVault() throws -> (root: URL, locked: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hn-unreadable-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<3 {
            try "# Note \(i)\n".write(to: root.appending(path: "Note \(i).md"),
                                      atomically: true, encoding: .utf8)
        }
        let locked = root.appending(path: "Locked Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        return (root, locked)
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }
    private func unlock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The folder is named, the system's own reason is quoted, and nothing
    /// claims a scan is running.
    @Test func anUnreadableFolderIsNamedInsteadOfCalledReindexing() async throws {
        let (root, locked) = try makeVault()
        defer { unlock(locked); try? FileManager.default.removeItem(at: root) }

        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        #expect(collection.staleReason == nil, "a clean vault is not stale")

        try lock(locked)

        // The first failing pass is allowed one retry, because on iOS a listing
        // can fail simply because the File Provider was not ready yet.
        await collection.rebuildFromScratch()
        #expect(collection.staleReason == .scanIncomplete,
                "the first failure schedules a retry rather than accusing the folder")

        // The retry finds it still unreadable. Now it is a real condition.
        await collection.rebuildFromScratch()
        let reason = try #require(collection.staleReason)
        guard case .foldersUnreadable(let count, let example, let why) = reason else {
            Issue.record("expected .foldersUnreadable, got \(reason)")
            return
        }
        #expect(count == 1)
        #expect(example.contains("Locked Folder"),
                "the message has to name the folder or it cannot be acted on — got \(example)")
        #expect(!why.isEmpty, "the system's reason is how you tell a permissions problem from a missing one")

        #expect(reason.explanation.contains("Locked Folder"))
        #expect(!reason.explanation.lowercased().contains("re-index"),
                "nothing is being re-indexed; the scan finished")
        #expect(!reason.explanation.lowercased().contains("until it finishes"),
                "there is nothing to finish")
        #expect(reason.isPermanent, "waiting will not fix a folder that cannot be read")
    }

    /// …and it goes away by itself once the folder can be read.
    ///
    /// The complaint was that it never disappeared. It has to disappear when
    /// the cause does, without the collection being closed and re-added.
    @Test func fixingTheFolderClearsTheWarning() async throws {
        let (root, locked) = try makeVault()
        defer { unlock(locked); try? FileManager.default.removeItem(at: root) }

        let collection = Collection(rootURL: root)
        try lock(locked)
        await collection.scanOffMain()
        await collection.rebuildFromScratch()
        #expect(collection.staleReason != nil, "it should be complaining at this point")

        unlock(locked)
        await collection.rebuildFromScratch()
        #expect(collection.staleReason == nil,
                "the folder is readable again and the warning is still on screen")
    }

    /// An interrupted scan keeps the old wording, because there a rescan really
    /// is owed and really does help. The two conditions were one case; the
    /// point of splitting them is that they say different things.
    @Test func anInterruptedScanStillReadsAsWorkInProgress() {
        #expect(CollectionState.StaleReason.scanIncomplete.isPermanent == false)
        #expect(CollectionState.StaleReason.eventsDropped.isPermanent == false)
        #expect(CollectionState.StaleReason.eventsDropped.summary == "Re-indexing")
        #expect(CollectionState.StaleReason
            .foldersUnreadable(count: 2, example: "a/b", why: "nope").summary
            == "2 folders unreadable")
    }
}

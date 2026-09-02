//
//  CollectionFreshnessTests.swift
//  HelloNotesTests
//
//  What the app shows must be what is on disk.
//
//  Two ways that stopped being true, reported together and unrelated in cause:
//
//    1. **Launch stopped noticing changes made while the app was closed.** The
//       startup walk was replaced by a read of `CollectionIndexCache`, on the
//       reasoning that the file watcher would report anything that moved. It
//       cannot: `DirectoryObserver` starts its stream at
//       `kFSEventStreamEventIdSinceNow`, so events from before the app launched
//       are never delivered — and the index cache is not a directory listing
//       anyway. It holds one record per *indexed* note, which on a cloud vault
//       deliberately omits every note that was still online-only.
//
//    2. **Rescan Collection did nothing on a collection that already had
//       notes.** Older than the above, and the reason the only reliable repair
//       was to close the collection and add it back: a *fresh* collection has
//       an empty note list, and an empty note list is the one condition under
//       which a scan that did not finish still publishes what it found.
//
//  Both are the same class of defect — a picture believed rather than checked —
//  so they are guarded in one place.
//

import Testing
import Foundation
@testable import HelloNotes

@Suite @MainActor
struct CollectionFreshnessTests {

    // MARK: - 1 · Launch

    /// Quit, change the folder, launch: the change is on screen.
    ///
    /// This is the reported regression. It is written against `activate`
    /// because that is the only thing a launch does — the fix has to be
    /// visible at the point the collection opens, not merely available from a
    /// menu the user should not have to find.
    @Test func openingACollectionNoticesWhatChangedWhileItWasClosed() async throws {
        let root = try Self.makeVault(noteCount: 4)
        defer { try? FileManager.default.removeItem(at: root) }

        // A first session, which leaves an index cache behind.
        let first = Collection(rootURL: root)
        await first.scanOffMain()
        #expect(first.notes.count == 4)
        first.refreshDerived()
        try await Self.settle()

        // The app is not running. Someone edits the folder: one note added by
        // hand, one deleted. Neither produces an FSEvent we will ever see.
        try "# Added while closed".write(
            to: root.appending(path: "Added.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "Note 0.md"))

        // A new session over the same folder.
        let second = Collection(rootURL: root)
        await second.activate(onExternalChange: {})
        defer { second.deactivate() }
        try await Self.settle()

        let titles = Set(second.notes.map(\.title))
        #expect(titles.contains("Added"),
                "a note added while the app was closed never appeared")
        #expect(!titles.contains("Note 0"),
                "a note deleted while the app was closed was still listed")
        #expect(second.notes.count == 4)
    }

    /// The index cache is not a directory listing, and must never be read as
    /// one.
    ///
    /// It holds a record per *indexed* note. `refreshDerived` deliberately skips
    /// notes whose contents are not local, so on a cloud vault the cache is a
    /// strict subset of the collection — opening from it silently drops every
    /// note that had not been downloaded yet. A negative control for the test
    /// above: it fails if the cache is trusted, and passes for the right reason
    /// only if the disk is consulted.
    @Test func aCacheHoldingFewerNotesThanTheFolderDoesNotDefineTheCollection() async throws {
        let root = try Self.makeVault(noteCount: 5)
        defer { try? FileManager.default.removeItem(at: root) }

        // A cache that knows about exactly one of the five notes, which is the
        // shape a part-downloaded cloud vault leaves behind.
        let partial = Collection(rootURL: root)
        await partial.scanOffMain()
        let one = try #require(partial.notes.first { $0.title == "Note 1" })
        let text = try String(contentsOf: one.fileURL, encoding: .utf8)
        CollectionIndexCache.save(
            [CollectionIndexCache.record(for: one, relativeTo: root, text: text)], for: root)

        let opened = Collection(rootURL: root)
        await opened.activate(onExternalChange: {})
        defer { opened.deactivate() }
        try await Self.settle()

        #expect(opened.notes.count == 5,
                "opened from a partial index cache and lost four notes that are on disk")
    }

    /// The verification is invisible when the folder has not moved.
    ///
    /// This is what makes checking on every launch affordable rather than
    /// something to be avoided. `revision` drives the sidebar outline's cache
    /// key, so a bump for an identical picture rebuilds the whole tree — and
    /// resets its scroll — once per launch for nothing. The cost of the check
    /// has to be zero in the common case, or the reason it was removed in the
    /// first place comes straight back.
    @Test func verifyingAnUnchangedFolderChangesNothing() async throws {
        let root = try Self.makeVault(noteCount: 4)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = Collection(rootURL: root)
        await first.scanOffMain()
        first.refreshDerived()
        try await Self.settle()

        let second = Collection(rootURL: root)
        await second.activate(onExternalChange: {})
        defer { second.deactivate() }
        let afterPaint = second.revision
        try await Self.settle()

        #expect(second.revision == afterPaint,
                "the verification pass republished an identical picture")
        #expect(second.notes.count == 4)
    }

    /// Notes that share a modification date are not a change.
    ///
    /// This is what CI kept failing on and this machine never did.
    /// `CollectionIndexCache.notes(for:)` sorts a **Dictionary's** values, and a
    /// dictionary's iteration order depends on the process's hash seed. With
    /// distinct dates the sort has something to order by and the result is
    /// stable; with a tie it has nothing, so the same notes come out in a
    /// different order on a different run — and comparing the two pictures as
    /// arrays of `Note` called that a change, republished, and rebuilt the
    /// whole sidebar.
    ///
    /// Ties are not exotic: files written in the same clock tick share a date,
    /// and so does anything copied or checked out as a batch.
    @Test func notesSharingAModificationDateAreNotAChange() async throws {
        let root = try Self.makeVault(noteCount: 5)
        defer { try? FileManager.default.removeItem(at: root) }

        // One date for all of them, so the sort has no tiebreaker at all.
        let shared = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for entry in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            try FileManager.default.setAttributes([.modificationDate: shared],
                                                  ofItemAtPath: root.appending(path: entry).path)
        }

        let first = Collection(rootURL: root)
        await first.scanOffMain()
        first.refreshDerived()
        try await Self.settle()

        // Repeated, because the failure is a coin toss on the ordering: one run
        // agreeing proves nothing.
        for attempt in 1...5 {
            let opened = Collection(rootURL: root)
            await opened.activate(onExternalChange: {})
            let afterPaint = opened.revision
            try await Self.settle()
            #expect(opened.revision == afterPaint,
                    "attempt \(attempt): the verification republished an identical picture")
            #expect(opened.notes.count == 5)
            opened.deactivate()
        }
    }

    // MARK: - 2 · Rescan

    /// Rescan Collection is the escape hatch. It has to actually rescan.
    ///
    /// The failure it guards is specific: on a collection that *already has
    /// notes*, a pass that does not finish publishes nothing, and the command
    /// reports success having changed nothing. On a freshly added collection
    /// the same pass publishes, which is why closing and re-adding worked and
    /// the menu item did not.
    @Test func rescanUpdatesACollectionThatAlreadyHasNotes() async throws {
        let root = try Self.makeVault(noteCount: 4)
        defer { try? FileManager.default.removeItem(at: root) }

        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        #expect(collection.notes.count == 4, "populated — this is the condition under test")

        try "# Later".write(to: root.appending(path: "Later.md"),
                            atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "Note 0.md"))

        collection.rescan()
        await collection.rebuildFromScratch()
        try await Self.settle()

        let titles = Set(collection.notes.map(\.title))
        #expect(titles.contains("Later"), "rescan did not pick up a new note")
        #expect(!titles.contains("Note 0"), "rescan did not drop a deleted note")
    }

    /// The negative control, and the actual mechanism of the bug.
    ///
    /// `WalkResult.isComplete` is `issues.isEmpty`, so a single directory the
    /// walk cannot list marks the whole pass incomplete — even though it
    /// drained the frontier and read every other folder. On a populated
    /// collection that verdict used to discard the entire pass.
    ///
    /// Without this test the fix is unguarded:
    /// `rescanUpdatesACollectionThatAlreadyHasNotes` passes either way, because
    /// a walk of a clean temporary folder has no issues and never reaches the
    /// branch at all.
    @Test func aScanThatCouldNotReadOneFolderStillPublishesTheRest() async throws {
        let root = try Self.makeVault(noteCount: 3)
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        #expect(collection.notes.count == 3, "populated, from a clean pass")

        // One folder the walk will not be able to list, and one new note beside
        // it that it will.
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try "# Beside".write(to: root.appending(path: "Beside.md"),
                             atomically: true, encoding: .utf8)

        await collection.rebuildFromScratch()
        try await Self.settle()

        #expect(collection.notes.contains { $0.title == "Beside" },
                "one unreadable folder threw away everything the walk did read")
    }

    /// The caution that verdict was protecting is kept, but made exact.
    ///
    /// A pass that drained its frontier from the root visited every directory
    /// except the ones it names, so it can tell a deletion from a blind spot.
    /// Both halves are asserted together because either one alone is satisfied
    /// by a wrong implementation: keeping everything passes the first, removing
    /// everything passes the second.
    @Test func anIncompletePassKeepsItsBlindSpotAndHonoursTheRest() async throws {
        let root = try Self.makeVault(noteCount: 3)
        let locked = root.appending(path: "locked", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "# Hidden".write(to: locked.appending(path: "Hidden.md"),
                             atomically: true, encoding: .utf8)

        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        #expect(collection.notes.count == 4, "three at the root, one inside the folder")

        // Now the folder cannot be read, and a note outside it is deleted.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path)
        try FileManager.default.removeItem(at: root.appending(path: "Note 0.md"))

        await collection.rebuildFromScratch()
        try await Self.settle()

        let titles = Set(collection.notes.map(\.title))
        // The paths, because this failed on CI and not here: if it fails again
        // the message has to say which spelling of the root each side used.
        #expect(titles.contains("Hidden"), """
            a note in the subtree the walk could not enter was removed on a guess.
            root:  \(root.path)
            notes: \(collection.notes.map(\.fileURL.path).sorted())
            """)
        #expect(!titles.contains("Note 0"),
                "a note the walk looked straight at and did not find was kept anyway")
        // The folder itself is a child of the root, and the root *was* listed —
        // so it survives even though its contents could not be read. Without
        // that the kept note would have no branch to sit on in the sidebar.
        #expect(collection.folders.contains { $0.lastPathComponent == "locked" },
                "the unreadable folder was dropped, orphaning the note inside it")
    }

    // MARK: -

    private static func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private static func makeVault(noteCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hn-freshness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<noteCount {
            try "# Note \(i)\n\nBody \(i).\n".write(
                to: root.appending(path: "Note \(i).md"), atomically: true, encoding: .utf8)
        }
        return root
    }
}

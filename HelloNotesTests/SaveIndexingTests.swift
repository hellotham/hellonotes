//
//  SaveIndexingTests.swift
//  HelloNotesTests
//
//  A save's index work is parsed off the main actor and applied on it
//  (`Collection.indexSaved`, docs/implemented.md §51.17). On the main actor it
//  was synchronous, and synchronous work happens in the order it was asked
//  for. Off it, parses finish in whatever order they finish — so each order the
//  old code had for free is held here: the newest save wins, a note that has
//  left is not put back, a rebuild begun under a save does not revert it, and
//  a changed alias still reaches the notes that link by it. And a save neither
//  cancels a rebuild nor is undone by one, begun before it or after (`KeptSave`).
//
//  Each race is staged with a hold (`WorkHold`): the save, the rebuild or the
//  relatedness build waits where the test holds it, and goes on when the test
//  lets it go. They were staged by size — a note of two to eight megabytes,
//  two hundred notes changed on disk — which made each race likely and never
//  certain: on a busy runner or a one-thread pool the race could be over
//  before it was looked at (implemented.md §51.81).
//

import Foundation
import Testing
@testable import HelloNotes

/// Serialized, because what these tests hold is the order in which work
/// lands. The holds make each order certain; one at a time keeps a failure
/// one test's.
@Suite(.serialized)
@MainActor
struct SaveIndexingTests {

    /// Hold the next `kind` of work: a note's next save (`path` the note's),
    /// or the collection's next rebuild or relatedness build (its folder's).
    /// Let go at the end of the test whatever happens — `defer` — or the work
    /// waits for ever.
    private func hold(_ kind: WorkHold.Kind, for path: String) -> WorkHold {
        WorkHold.arm(kind, for: path)
    }

    /// Whether `condition` comes to hold within `timeout`, sleeping between
    /// looks.
    private func eventually(timeout: Duration = .seconds(10),
                            _ condition: () async -> Bool) async -> Bool {
        // Looks, not seconds — a deadline on the clock runs out while another
        // test has the main actor (`Waits`).
        for _ in 0..<Waits.looks(in: timeout, every: .milliseconds(10)) {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// A folder holding `files` (title → text), scanned and indexed.
    private func indexedCollection(_ files: [String: String]) async throws -> (Collection, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveIndexing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (title, text) in files {
            try Data(text.utf8).write(to: root.appendingPathComponent("\(title).md"))
        }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        let unindexed = collection.derivedRevision
        collection.refreshDerived()
        #expect(await eventually { collection.derivedRevision != unindexed }, "the collection was never indexed")
        return (collection, root)
    }

    /// Write `text` into the note and tell its collection — what every writer
    /// does: an editor's save (`onSaved`), the Assistant's tools, `append`.
    private func save(_ text: String, to title: String, in collection: Collection) throws {
        let note = try #require(collection.note(titled: title))
        try Data(text.utf8).write(to: note.fileURL)
        collection.noteDidSave(note.fileURL, text: text)
    }

    /// Every save parsed, and applied or superseded.
    private func settled(_ collection: Collection) async {
        #expect(await eventually { collection.savesBeingIndexed == 0 }, "a save was never indexed")
    }

    private func links(of title: String, in collection: Collection) -> [String] {
        guard let note = collection.note(titled: title) else { return [] }
        return collection.linkGraph.outgoingLinks(for: note, in: collection.notes).map(\.title)
    }

    /// The positive control for everything below: a save reaches the link
    /// graph, the search index — aliases, tags, headings — and a relatedness
    /// index that has been built.
    @Test func aSaveReachesEveryIndex() async throws {
        let (collection, root) = try await indexedCollection([
            "Note": "Plain.", "Target": "Target.",
            "Other": "Something else entirely, long enough to be worth relating to anything that asks about it.",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try #require(collection.note(titled: "Note"))
        _ = await collection.relatedNotes(to: "something", excluding: nil)

        try save("""
            ---
            aliases: [Nick]
            tags: [saved]
            ---
            # Heading

            Links to [[Target]]: zanzibar, zanzibar, zanzibar — and enough after it to be worth relating.
            """, to: "Note", in: collection)
        await settled(collection)

        #expect(links(of: "Note", in: collection) == ["Target"])
        #expect(collection.search.aliases(of: note.fileURL) == ["Nick"])
        #expect(collection.search.notesTagged("saved").map(\.title) == ["Note"])
        #expect(collection.search.headings(forName: "Note") == ["Heading"])
        #expect(await eventually {
            await collection.relatedNotes(to: "zanzibar zanzibar", excluding: nil).contains { $0.url == note.fileURL }
        }, "the relatedness index never heard of the save")
    }

    /// Two saves of one note, the first held: the second lands first, and the
    /// first, landing last, must not put its links back over it.
    @Test func anOlderSaveThatLandsLastIsNotApplied() async throws {
        let (collection, root) = try await indexedCollection(["Note": "Plain.", "Old": "Old.", "New": "New."])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = hold(.saveParse, for: try #require(collection.note(titled: "Note")).fileURL.path)
        defer { first.release() }

        try save("Links to [[Old]].\n", to: "Note", in: collection)
        try save("Links to [[New]].\n", to: "Note", in: collection)
        #expect(await eventually { links(of: "Note", in: collection) == ["New"] }, "the newer save never landed")
        #expect(await eventually { first.isReached }, "the first save never came to its hold")
        first.release()
        await settled(collection)

        #expect(links(of: "Note", in: collection) == ["New"], "the older save was applied over the newer one")
    }

    /// The same, with the index settled in between: the second save has
    /// landed, and a third is made while the first is still held — and the
    /// first lands while the third is out. Numbered per note and cleared once
    /// applied, the third would be save 1 again — and the first, landing,
    /// would pass for it.
    @Test func aSaveStillParsingAfterANewerOneLandedIsNeverApplied() async throws {
        let (collection, root) = try await indexedCollection([
            "Note": "Plain.", "Old": "Old.", "New": "New.", "Third": "Third.",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try #require(collection.note(titled: "Note")).fileURL.path
        let first = hold(.saveParse, for: path)
        defer { first.release() }

        try save("Links to [[Old]].\n", to: "Note", in: collection)
        try save("Links to [[New]].\n", to: "Note", in: collection)
        #expect(await eventually { links(of: "Note", in: collection) == ["New"] }, "the second save never landed")
        #expect(collection.savesBeingIndexed == 1, "the first save is not still out")

        let third = hold(.saveParse, for: path)
        defer { third.release() }
        try save("Links to [[Third]].\n", to: "Note", in: collection)
        #expect(await eventually { first.isReached && third.isReached }, "a save never came to its hold")
        first.release()
        #expect(await eventually { collection.savesBeingIndexed == 1 }, "the first save never landed")
        #expect(links(of: "Note", in: collection) == ["New"], "the first save was applied while the third was out")
        third.release()
        await settled(collection)

        #expect(links(of: "Note", in: collection) == ["Third"], "an earlier save was applied over a later one")
    }

    /// A note removed while its save is parsed — by the Finder, by a sync —
    /// and seen by a scan and the rebuild that follows one. Applied anyway,
    /// the save would put it back into the indexes: its alias resolving to a
    /// file that is not there, and an entry for it in search and Open Quickly.
    @Test func aNoteThatLeavesWhileItsSaveIsParsedIsNotPutBack() async throws {
        let (collection, root) = try await indexedCollection(["Doomed": "Plain.", "Target": "Target."])
        defer { try? FileManager.default.removeItem(at: root) }
        let doomed = try #require(collection.note(titled: "Doomed"))
        let saving = hold(.saveParse, for: doomed.fileURL.path)
        defer { saving.release() }

        try save("---\naliases: [Ghost]\n---\nLinks to [[Target]].\n", to: "Doomed", in: collection)
        try FileManager.default.removeItem(at: doomed.fileURL)
        await collection.scanOffMain()
        let scanned = collection.derivedRevision
        collection.refreshDerived()
        #expect(await eventually { collection.derivedRevision != scanned }, "the rebuild after the scan never landed")
        #expect(collection.savesBeingIndexed == 1, "the save is not still out")
        saving.release()
        await settled(collection)

        #expect(collection.linkGraph.resolve("Ghost") == nil, "a note that has left is back in the link graph")
        #expect(collection.search.aliases(of: doomed.fileURL).isEmpty, "a note that has left is back in search")
    }

    /// A rebuild reads each note's record from the cache when the file's
    /// size and date still match it — and a save does not change the date
    /// the collection holds, so a rebuild begun under a save takes the saved
    /// note's *old* record. Landing after the save was applied, it would put
    /// the old links back. Here it is begun while the save is parsed, and
    /// held until the save has landed.
    @Test func aRebuildBegunWhileASaveIsParsedDoesNotPutTheOldLinksBack() async throws {
        let (collection, root) = try await indexedCollection(["Note": "Links to [[Old]].", "Old": "Old.", "New": "New."])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(links(of: "Note", in: collection) == ["Old"])
        let rebuild = hold(.rebuild, for: collection.rootURL.path)
        defer { rebuild.release() }

        try save("Links to [[New]].", to: "Note", in: collection)
        collection.refreshDerived()
        #expect(await eventually { rebuild.isReached }, "the rebuild never read the notes")
        await settled(collection)
        #expect(links(of: "Note", in: collection) == ["New"], "the save never landed")
        let saved = collection.derivedRevision
        rebuild.release()
        #expect(await eventually { collection.derivedRevision != saved }, "the rebuild never landed")

        #expect(links(of: "Note", in: collection) == ["New"], "a stale rebuild put the saved note's old links back")
    }

    /// A rename rewrites the `[[links]]` in the notes the link graph says link
    /// to the renamed one — and the shell flushes every tab just before it
    /// renames, so a link typed a moment ago is in a save still being parsed.
    /// Asked then, the graph did not know it, and the link was left naming a
    /// note that no longer exists.
    ///
    /// The save is held until the rename is seen waiting for it
    /// (`waitingForSaves`). Let go at the rename's first wait, whatever that
    /// was for, it landed while the rename looked at the disk — and the test
    /// passed with the rename not waiting at all.
    @Test func aRenameRewritesALinkSavedJustBeforeIt() async throws {
        let (collection, root) = try await indexedCollection(["Target": "Target.", "Linker": "Plain."])
        defer { try? FileManager.default.removeItem(at: root) }
        let saving = hold(.saveParse, for: try #require(collection.note(titled: "Linker")).fileURL.path)
        defer { saving.release() }

        try save("See [[Target]].\n", to: "Linker", in: collection)
        #expect(collection.savesBeingIndexed == 1, "the save is not still out")
        let target = try #require(collection.note(titled: "Target"))
        let renaming = Task { await collection.renameNote(target, to: "Renamed") }
        #expect(await eventually(timeout: .seconds(3)) { collection.waitingForSaves == 1 },
                "the rename did not wait for the save still out")
        saving.release()
        _ = try #require(await renaming.value)

        let linker = root.appendingPathComponent("Linker.md")
        #expect(await eventually { (try? FileIO.readString(at: linker))?.hasPrefix("See [[Renamed]].") == true },
                "the link saved just before the rename still names the old title")
    }

    /// A rename's re-index is a rebuild, and a save's patch cancelled the
    /// rebuild in flight when it landed: a save landing during the rename's
    /// rebuild, and the renamed note was never indexed under its new name.
    /// The rename waits for the saves already made (`savesIndexed`), so the
    /// save that lands during its rebuild is one made after it — a tab saving
    /// as the person goes on typing — and the rebuild is held until it has.
    @Test func aRenameIsIndexedWhenASaveIsParsedAcrossIt() async throws {
        let (collection, root) = try await indexedCollection(["Target": "Target.", "Other": "Plain."])
        defer { try? FileManager.default.removeItem(at: root) }
        let rebuild = hold(.rebuild, for: collection.rootURL.path)
        defer { rebuild.release() }

        let target = try #require(collection.note(titled: "Target"))
        let renamed = try #require(await collection.renameNote(target, to: "Renamed"))
        #expect(await eventually { rebuild.isReached }, "the rename's rebuild never read the notes")
        try save("Changed.\n", to: "Other", in: collection)
        await settled(collection)
        rebuild.release()

        #expect(await eventually { collection.linkGraph.resolve("Renamed") == renamed.fileURL },
                "the renamed note was never indexed under its new name")
    }

    /// A note deleted while its save is parsed and made again at the same path
    /// is a new note: the old save must not be applied to it.
    @Test func aNoteMadeAgainWhileItsOldSaveIsParsedIsNotGivenIt() async throws {
        let (collection, root) = try await indexedCollection(["Doomed": "Plain."])
        defer { try? FileManager.default.removeItem(at: root) }
        let doomed = try #require(collection.note(titled: "Doomed"))
        let saving = hold(.saveParse, for: doomed.fileURL.path)
        defer { saving.release() }

        try save("---\naliases: [Ghost]\n---\nPlain.\n", to: "Doomed", in: collection)
        try FileManager.default.removeItem(at: doomed.fileURL)
        let again = try #require(await collection.createNote(title: "Doomed"))
        #expect(again.fileURL == doomed.fileURL, "it was not made at the same path, so this tests nothing")
        #expect(collection.savesBeingIndexed == 1, "the old save is not still out")
        saving.release()
        await settled(collection)

        #expect(collection.linkGraph.resolve("Ghost") == nil, "the old save's alias was given to the new note")
        #expect(collection.search.aliases(of: again.fileURL).isEmpty, "the old save's alias was given to the new note")
    }

    // MARK: - A rebuild and a save

    /// A save patches the indexes in place and leaves the collection's record
    /// of the note's size and date as they were — so a rebuild from the index
    /// cache, which takes a note's cached record while those still match it,
    /// put the note's pre-save links back: here the rebuild an alias change on
    /// another note asks for, 800 ms after its save. The control: a walk first,
    /// which reads the saved note's new size and date, so the rebuild re-reads
    /// it from disk — and keeps the save, before the fix as after.
    @Test func aRebuildAfterASaveKeepsWhatWasSaved() async throws {
        for walkedFirst in [true, false] {
            let (collection, root) = try await indexedCollection([
                "A": "Links to [[Old]].", "Old": "Old.", "New": "New.", "B": "Plain.",
            ])
            defer { try? FileManager.default.removeItem(at: root) }
            try save("Links to [[New]].", to: "A", in: collection)
            await settled(collection)
            #expect(links(of: "A", in: collection) == ["New"])
            if walkedFirst { await collection.scanOffMain() }

            let before = collection.derivedRevision
            try save("---\naliases: [Bee]\n---\nPlain.\n", to: "B", in: collection)
            #expect(await eventually { collection.derivedRevision >= before + 2 },
                    "the rebuild the alias change asks for never landed")
            #expect(links(of: "A", in: collection) == ["New"],
                    "a rebuild put the saved note's old links back (walked first: \(walkedFirst))")
        }
    }

    /// A save's patch cancelled whatever rebuild was in flight — meant for one
    /// that had read the saved note's old record — and nothing ran it again.
    /// Here the rebuild is the one a changed alias asks for, 800 ms after its
    /// save: a note saved within them, changing nothing but itself, cancelled
    /// it, and the link by the new alias never became a backlink. The control:
    /// without that save, it does (as `aChangedAliasReachesTheNotesThatLinkByIt`).
    @Test func aSaveDoesNotCancelTheRebuildAnAliasChangeAskedFor() async throws {
        for savedBetween in [false, true] {
            let (collection, root) = try await indexedCollection([
                "Linker": "See [[Nick]].", "Person": "Plain.", "Other": "Plain.",
            ])
            defer { try? FileManager.default.removeItem(at: root) }
            let person = try #require(collection.note(titled: "Person"))
            try save("---\naliases: [Nick]\n---\nPlain.\n", to: "Person", in: collection)
            await settled(collection)
            if savedBetween {
                try save("Changed.", to: "Other", in: collection)
                await settled(collection)
            }
            #expect(await eventually {
                collection.linkGraph.backlinks(for: person, in: collection.notes).map(\.title) == ["Linker"]
            }, "the link by the new alias never became a backlink (a save in between: \(savedBetween))")
        }
    }

    /// A delete takes the note out of the link graph and search by rebuilding
    /// them — neither has a single-entry removal — and a save landing while
    /// that rebuild ran cancelled it: the deleted note went on answering to its
    /// alias. The control: without the save, it does not. Both indexes are
    /// asked in one look, because a rebuild loads the link graph and then
    /// awaits search's.
    @Test func aSaveDoesNotCancelTheRebuildADeleteAskedFor() async throws {
        for savedDuring in [false, true] {
            let (collection, root) = try await indexedCollection([
                "Doomed": "---\naliases: [Ghost]\n---\nPlain.", "Other": "Plain.",
            ])
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(collection.linkGraph.resolve("Ghost") != nil)
            let rebuild = hold(.rebuild, for: collection.rootURL.path)
            defer { rebuild.release() }

            let doomed = try #require(collection.note(titled: "Doomed"))
            await collection.deleteNote(doomed)
            #expect(await eventually { rebuild.isReached }, "the delete's rebuild never read the notes")
            if savedDuring { try save("Changed.", to: "Other", in: collection) }
            await settled(collection)
            rebuild.release()
            #expect(await eventually {
                collection.linkGraph.resolve("Ghost") == nil && collection.search.aliases(of: doomed.fileURL).isEmpty
            }, "the deleted note is still in the link graph or search (a save during the rebuild: \(savedDuring))")
        }
    }

    /// A walk — on opening a collection, after a change made outside the app —
    /// is followed by a rebuild, and a save landing while it ran cancelled it:
    /// what the walk found never reached the indexes. The control: without the
    /// save, it does.
    @Test func aSaveDoesNotCancelTheRebuildAfterAWalk() async throws {
        for savedDuring in [false, true] {
            let (collection, root) = try await indexedCollection([
                "Edited elsewhere": "Plain.", "Target": "Target.", "Other": "Plain.",
            ])
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("Links to [[Target]].\n".utf8).write(to: root.appendingPathComponent("Edited elsewhere.md"))
            let rebuild = hold(.rebuild, for: collection.rootURL.path)
            defer { rebuild.release() }

            // What `reconcileSoon` and `verifyAgainstFolder` do.
            await collection.scanOffMain()
            collection.refreshDerived()
            #expect(await eventually { rebuild.isReached }, "the rebuild never read the notes")
            if savedDuring { try save("Changed.", to: "Other", in: collection) }
            await settled(collection)
            rebuild.release()
            #expect(await eventually { links(of: "Edited elsewhere", in: collection) == ["Target"] },
                    "a change the walk found never reached the link graph (a save during the rebuild: \(savedDuring))")
        }
    }

    /// A save's patch folds the search index's aggregates — tags, link targets,
    /// Open Quickly — a moment later, from the entries it saw then. A rebuild
    /// landing in that moment replaced the entries, and the fold, landing after
    /// it, put the older picture's tags back over the newer one. Two things
    /// hold it now, and the test fails only with both taken out: the fold
    /// takes its snapshot when it runs, not when it was scheduled, and a
    /// rebuild's `load` cancels a fold still waiting or already folding. The
    /// control: with no rebuild after it, the fold is what brings the saved
    /// tag in.
    @Test func aRebuildIsNotUndoneByTheFoldASaveLeftWaiting() async throws {
        func record(_ tags: [String]) -> NoteIndexRecord {
            NoteIndexRecord(relativePath: "", mtime: 0, size: 1, aliases: [], tags: tags, headings: [], outgoing: [])
        }
        let a = Note(title: "A", fileURL: URL(fileURLWithPath: "/SaveIndexing/A.md"), lastModified: .now, fileSize: 1)
        let b = Note(title: "B", fileURL: URL(fileURLWithPath: "/SaveIndexing/B.md"), lastModified: .now, fileSize: 1)
        for rebuilt in [false, true] {
            let search = CollectionSearchModel()
            await search.load(pairs: [(a, record(["old"]))])
            search.updateNote(b, headings: [], tags: ["saved"], aliases: [])
            guard rebuilt else {
                #expect(await eventually { search.allTags() == ["old", "saved"] }, "the save's fold never landed")
                continue
            }
            await search.load(pairs: [(a, record(["new"])), (b, record(["saved"]))])
            // Well past the fold's wait, the newer picture still stands.
            var patience = Waits.Patience(.milliseconds(1_000))
            while patience.lasts, search.allTags() == ["new", "saved"] {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(search.allTags() == ["new", "saved"], "a fold of the older entries landed over the rebuild")
        }
    }

    /// Saves that land while a rebuild builds search are patched in again
    /// after it, several at once (`updateNotes`): an entry that is there is
    /// replaced, one that is not is added, and the lookup and the fold follow.
    @Test func severalSavesArePatchedIntoSearchAtOnce() async throws {
        func record(_ tags: [String]) -> NoteIndexRecord {
            NoteIndexRecord(relativePath: "", mtime: 0, size: 1, aliases: [], tags: tags, headings: [], outgoing: [])
        }
        let a = Note(title: "A", fileURL: URL(fileURLWithPath: "/SaveIndexing/A.md"), lastModified: .now, fileSize: 1)
        let b = Note(title: "B", fileURL: URL(fileURLWithPath: "/SaveIndexing/B.md"), lastModified: .now, fileSize: 1)
        let c = Note(title: "C", fileURL: URL(fileURLWithPath: "/SaveIndexing/C.md"), lastModified: .now, fileSize: 1)
        let search = CollectionSearchModel()
        await search.load(pairs: [(a, record(["a"])), (b, record(["b"]))])

        search.updateNotes([(note: b, headings: [], tags: ["b2"], aliases: ["Bee"]),
                            (note: c, headings: [], tags: ["c"], aliases: [])])

        #expect(search.aliases(of: b.fileURL) == ["Bee"])
        #expect(search.notesTagged("b").isEmpty && search.notesTagged("b2").map(\.title) == ["B"])
        #expect(search.notesTagged("c").map(\.title) == ["C"])
        #expect(await eventually { search.allTags() == ["a", "b2", "c"] }, "the fold never followed")
    }

    /// A rebuild cannot be stopped once it is reading, so one replaced by a
    /// newer rebuild still finishes — and wrote the index cache when it did,
    /// after the newer one if it came to that. The newer one may have let go
    /// of a save it read from disk, which the older one took from the cache as
    /// it was before the save: written last, the save's old record was the
    /// cache's answer for the note at the next rebuild. The controls: written
    /// in order, the newer records stand, and an unnumbered write — seeding a
    /// cache — always lands.
    @Test func anOlderRebuildNeverWritesTheCacheOverANewerOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveIndexing-\(UUID().uuidString)", isDirectory: true)
        defer { CollectionIndexCache.remove(for: root) }
        func record(_ link: String) -> NoteIndexRecord {
            NoteIndexRecord(relativePath: "X.md", mtime: 0, size: 1, aliases: [], tags: [], headings: [], outgoing: [link])
        }
        func cached() -> [String]? { CollectionIndexCache.load(for: root)?["X.md"]?.outgoing }

        let older = CollectionIndexCache.rebuildNumber()
        let newer = CollectionIndexCache.rebuildNumber()
        _ = CollectionIndexCache.save([record("New")], for: root, rebuild: newer)
        _ = CollectionIndexCache.save([record("Old")], for: root, rebuild: older)
        #expect(cached() == ["New"], "an older rebuild wrote the cache over a newer one")

        CollectionIndexCache.save([record("Newest")], for: root, rebuild: CollectionIndexCache.rebuildNumber())
        #expect(cached() == ["Newest"], "a newer rebuild could not write")
        CollectionIndexCache.save([record("Seeded")], for: root)
        #expect(cached() == ["Seeded"], "an unnumbered write did not land")
    }

    /// Rescan removes the index cache so that nothing it held is trusted
    /// again — and a rebuild begun before it, still reading, wrote the cache
    /// back when it finished, with what it had read from the removed one. The
    /// control: a rebuild begun after the removal writes.
    @Test func aRebuildBegunBeforeARescanCannotWriteTheCacheBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveIndexing-\(UUID().uuidString)", isDirectory: true)
        defer { CollectionIndexCache.remove(for: root) }
        func record(_ link: String) -> NoteIndexRecord {
            NoteIndexRecord(relativePath: "X.md", mtime: 0, size: 1, aliases: [], tags: [], headings: [], outgoing: [link])
        }
        let seeded = CollectionIndexCache.save([record("Old")], for: root, rebuild: CollectionIndexCache.rebuildNumber())
        #expect(seeded)
        let inFlight = CollectionIndexCache.rebuildNumber()

        CollectionIndexCache.remove(for: root)
        let stale = CollectionIndexCache.save([record("Stale")], for: root, rebuild: inFlight)
        #expect(!stale, "a rebuild begun before the rescan wrote the cache back")
        #expect(CollectionIndexCache.load(for: root) == nil)

        let fresh = CollectionIndexCache.save([record("Fresh")], for: root, rebuild: CollectionIndexCache.rebuildNumber())
        #expect(fresh, "a rebuild begun after the rescan could not write")
        #expect(CollectionIndexCache.load(for: root)?["X.md"]?.outgoing == ["Fresh"])
    }

    /// A write of the cache that fails says so and leaves the cache's number
    /// where it was: counted as written, it barred every rebuild between, and
    /// the rebuild that failed went on to let go of saves the cache did not
    /// hold (`Collection.withKeptSaves`). A directory where the file goes makes
    /// the write fail. The control: once it can be written, it is.
    @Test func aFailedCacheWriteIsNotCountedAsWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveIndexing-\(UUID().uuidString)", isDirectory: true)
        let file = CollectionIndexCache.cacheURL(for: root)
        defer { try? FileManager.default.removeItem(at: file) }
        func record(_ link: String) -> NoteIndexRecord {
            NoteIndexRecord(relativePath: "X.md", mtime: 0, size: 1, aliases: [], tags: [], headings: [], outgoing: [link])
        }
        let older = CollectionIndexCache.rebuildNumber()
        let failing = CollectionIndexCache.rebuildNumber()
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let failed = CollectionIndexCache.save([record("Failed")], for: root, rebuild: failing)
        #expect(!failed, "a write that failed said it had written")

        try FileManager.default.removeItem(at: file)
        let written = CollectionIndexCache.save([record("Written")], for: root, rebuild: older)
        #expect(written, "a failed write was counted, and barred a rebuild older than it")
        #expect(CollectionIndexCache.load(for: root)?["X.md"]?.outgoing == ["Written"])
    }

    /// A new note is patched into the indexes the way a save is, and a rebuild
    /// begun before it was made — which never saw it — landed without it: it
    /// did not resolve as a link and was not offered as one until something
    /// rebuilt them again. The control: made with no rebuild in flight, it is.
    @Test func aNoteMadeWhileARebuildRunsStaysInTheIndexes() async throws {
        for rebuilding in [false, true] {
            let (collection, root) = try await indexedCollection(["Other": "Plain."])
            defer { try? FileManager.default.removeItem(at: root) }
            let rebuild = hold(.rebuild, for: collection.rootURL.path)
            defer { rebuild.release() }

            let before = collection.derivedRevision
            if rebuilding {
                collection.refreshDerived()
                #expect(await eventually { rebuild.isReached }, "the rebuild never read the notes")
            }
            let fresh = try #require(await collection.createNote(title: "Fresh"))
            if rebuilding {
                #expect(collection.derivedRevision == before + 1,
                        "the rebuild landed before the note was made, so this tests nothing")
                rebuild.release()
                #expect(await eventually { collection.derivedRevision >= before + 2 }, "the rebuild never landed")
            }
            #expect(collection.linkGraph.resolve("Fresh") == fresh.fileURL,
                    "the new note does not resolve (a rebuild in flight: \(rebuilding))")
            #expect(await eventually(timeout: .seconds(2)) { collection.search.linkTargets().contains("Fresh") },
                    "the new note is not offered as a link (a rebuild in flight: \(rebuilding))")
        }
    }

    /// The relatedness index is built on first use, from the notes as they
    /// were when the build began — and until it lands there is no index for a
    /// save to update, so a save made while it was built reached neither: the
    /// note stayed as the build had read it until the whole index was dropped.
    /// The build is held once it has read every note, the saved one among
    /// them. The control: saved once the index exists, it is updated.
    @Test func aSaveMadeWhileRelatednessIsBuiltReachesIt() async throws {
        for savedDuring in [false, true] {
            let plain = "Plain, and long enough to be worth relating to anything that asks about it at all."
            let other = "Something else entirely, and long enough to be worth relating to anything that asks."
            let (collection, root) = try await indexedCollection(["Note": plain, "Other": other])
            defer { try? FileManager.default.removeItem(at: root) }
            let build = hold(.relatednessBuild, for: collection.rootURL.path)
            defer { build.release() }

            let building = Task { await collection.relatedNotes(to: "something", excluding: nil) }
            if savedDuring {
                #expect(await eventually { build.isReached }, "the build never read the notes")
                #expect(!collection.hasRelatednessIndex, "the index was built before the save, so this tests nothing")
            } else {
                build.release()
                _ = await building.value
            }
            try save("Zanzibar, zanzibar, zanzibar — and enough after it to be worth relating to anything.",
                     to: "Note", in: collection)
            await settled(collection)
            build.release()
            _ = await building.value
            let note = try #require(collection.note(titled: "Note"))
            #expect(await eventually(timeout: .seconds(3)) {
                await collection.relatedNotes(to: "zanzibar zanzibar", excluding: nil).contains { $0.url == note.fileURL }
            }, "the save never reached the relatedness index (saved while it was built: \(savedDuring))")
        }
    }

    /// A save that changes a note's aliases changes how *other* notes' links
    /// resolve, which the saved note's own entry cannot say — so it rebuilds
    /// the link graph. Whether they changed is asked of the index before the
    /// save is applied to it; asked after, it is always "no".
    @Test func aChangedAliasReachesTheNotesThatLinkByIt() async throws {
        let (collection, root) = try await indexedCollection(["Linker": "See [[Nick]].", "Person": "Plain."])
        defer { try? FileManager.default.removeItem(at: root) }
        let person = try #require(collection.note(titled: "Person"))
        #expect(collection.linkGraph.backlinks(for: person, in: collection.notes).isEmpty)

        try save("---\naliases: [Nick]\n---\nPlain.\n", to: "Person", in: collection)

        #expect(await eventually {
            collection.linkGraph.backlinks(for: person, in: collection.notes).map(\.title) == ["Linker"]
        }, "a link by the new alias never became a backlink")
    }
}

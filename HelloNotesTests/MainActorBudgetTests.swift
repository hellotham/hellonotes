//
//  MainActorBudgetTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 18/8/2026.
//

import Testing
import Foundation
import SwiftUI
import MarkdownEditor
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The golden rule, as a number.
///
/// > The main editor loop can never be blocked for any reason — folder scans,
/// > search, index rebuild, AI, anything.
///
/// A rule stated in prose is a rule that gets argued with. Twice now a fix was
/// justified by reasoning about which code runs on which thread, and twice the
/// reasoning was locally correct and the editor still froze. So the rule is
/// measured instead: a background task asks the main actor to answer, over and
/// over, while the app does its worst — and records how long it ever had to wait.
///
/// **These tests are expected to FAIL until the indexer work lands.** They are
/// the baseline, written first on purpose. A failure here is the bug, printed as
/// a number, and the number is what says whether a change helped.
/// **Run this suite alone**, and never as part of the whole test run:
///
///     xcodebuild test -project HelloNotes.xcodeproj -scheme HelloNotes \
///       -destination 'platform=macOS' \
///       -only-testing:HelloNotesTests/MainActorBudgetTests
///
/// It is **skipped unless `HN_BUDGET_TESTS` is set**, because it cannot give a
/// true answer inside a full run and a suite that always fails is a suite
/// everyone learns to ignore:
///
///     HN_BUDGET_TESTS=1 ./scripts/run-tests.sh \
///       -only-testing:HelloNotesTests/MainActorBudgetTests
///
/// It measures main-thread CPU, and the main thread is shared. Swift Testing
/// runs tests concurrently and every test in this target is `@MainActor`, so a
/// measurement taken during a normal run also counts whatever *other* tests
/// were doing on the main thread at the time — which read as 3.4 seconds of CPU
/// for a test whose entire body is a two-second sleep. `.serialized` fixes the
/// contention inside this suite; running the suite by itself fixes the rest.
///
/// This is the fourth instrument for this measurement and the third to be caught
/// by its own control. The controls stay first in the file for that reason.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HN_BUDGET_TESTS"] != nil,
                             "measures main-thread CPU; set HN_BUDGET_TESTS=1 and run this suite alone"))
@MainActor
struct MainActorBudgetTests {

    /// How much main-thread CPU an operation may consume. 100ms is roughly six
    /// dropped frames — past "a person notices" and well short of "an ordinary
    /// layout pass".
    private static let budget: Double = 0.100

    /// How much CPU the **main thread** burns while `work` runs.
    ///
    /// Third instrument, and the first one that survives its own control.
    ///
    /// Two dispatch-latency probes came before it and both lied. The first ran
    /// on the cooperative pool and measured its own starvation by the walk's
    /// file I/O. The second used a real `Thread` — and still reported ~3s on a
    /// completely idle main actor, because inside a `@MainActor` test the
    /// harness parks the main thread instead of servicing its runloop, so
    /// nothing queued with `DispatchQueue.main.async` runs until the test's
    /// `await` returns. Latency is simply not measurable from in here.
    ///
    /// CPU time is, and it answers the question that actually matters: the rule
    /// is "the main thread does not do this work", and a thread that is not
    /// doing work does not burn CPU. It needs no runloop, no second thread and
    /// no assumptions about scheduling — and unlike latency it cannot be
    /// inflated by the harness.
    private func mainThreadCPU(
        while work: @MainActor () async -> Void
    ) async -> Double {
        let before = Self.mainThreadCPUSeconds()
        await work()
        return Self.mainThreadCPUSeconds() - before
    }

    /// Cumulative user+system CPU seconds for the calling thread. `@MainActor`
    /// callers therefore measure the main thread.
    private static func mainThreadCPUSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }

        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
             + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    /// Retained only for reference; see `mainThreadCPU`.
    private func worstMainActorLatency(
        while work: @MainActor () async -> Void
    ) async -> Duration {
        let recorder = LatencyRecorder()
        // A dedicated `Thread`, **not** `Task.detached`.
        //
        // The first version of this probe used a detached task, which runs on
        // the cooperative pool — the same pool the walk saturates with blocking
        // file I/O. The probe was then starved *after* dispatching to main, so
        // the interval it measured included its own descheduling and had
        // nothing to do with the main actor. It reported 2.3s before a change
        // that moved work off the main actor, and 2.8s after: an instrument
        // measuring the wrong thing, and reporting no improvement because it
        // could not see one. A real thread cannot be starved by the pool.
        // (`MainActorWatchdog` uses a `Thread` for exactly this reason.)
        let probe = Thread {
            while !Thread.current.isCancelled {
                let asked = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + .seconds(60)) == .timedOut {
                    recorder.record(.seconds(60))
                    return
                }
                recorder.record(ContinuousClock.now - asked)
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        probe.qualityOfService = .userInitiated
        probe.start()
        await work()
        probe.cancel()
        return recorder.worst
    }

    /// A vault of `noteCount` notes spread over a directory tree.
    private func makeVault(noteCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-budget-\(UUID().uuidString)", isDirectory: true)
        let perFolder = 20
        for index in 0..<noteCount {
            let folder = root.appendingPathComponent("d\(index / perFolder)", isDirectory: true)
            if index % perFolder == 0 {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("# Note \(index)\n\nBody with [[Note \(index % 50)]] and #tag\(index % 30).\n".utf8)
                .write(to: folder.appendingPathComponent("Note \(index).md"))
        }
        return root
    }

    // MARK: - Controls, so the instrument is not the thing being measured

    /// The probe must report ~nothing when nothing is happening.
    ///
    /// Without this, every number below is unfalsifiable. The first version of
    /// this probe ran on the cooperative pool and reported seconds of "main
    /// actor latency" that were really its own starvation — a believable number,
    /// moving in a believable direction, and entirely wrong.
    @Test func theProbeReportsNothingWhenNothingBlocks() async {
        let cpu = await mainThreadCPU {
            try? await Task.sleep(for: .seconds(2))
        }
        print("CONTROL idle: main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "the instrument reports \(cpu)s of CPU on an idle main thread")
    }

    /// The walk alone, with no `Collection` involved. If this blocks, the
    /// problem is in the walk or its source, not in what consumes it.
    @Test func theWalkAloneDoesNotBlockTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let cpu = await mainThreadCPU {
            let source = LocalTreeSource(root: root)
            _ = await Task.detached(priority: .userInitiated) {
                await ResumableTreeWalk.run(source: source) { _ in }
            }.value
        }
        print("CONTROL walk-only(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget,
                "the walk burned \(cpu)s of main-thread CPU with no Collection involved")
    }

    // MARK: - The measurements

    /// Scanning a realistic vault must not block the editor. This is the
    /// reported bug, expressed as an assertion.
    @Test func scanningALargeVaultNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)

        let cpu = await mainThreadCPU {
            await collection.scanOffMain()
        }
        print("BUDGET scan(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget,
                "a scan burned \(cpu)s of main-thread CPU; the editor is unusable for that long")
    }

    /// Rebuilding the derived indexes must not block it either — `refreshDerived`
    /// creates a `Task { }` from a `@MainActor` context, which *inherits* the
    /// main actor, so the link-graph rebuild is main-thread work despite looking
    /// asynchronous.
    @Test func rebuildingDerivedIndexesNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()

        let cpu = await mainThreadCPU {
            collection.refreshDerived(force: true)
            // Give the rebuild time to actually run; the call itself returns
            // immediately and the work is what we are measuring.
            try? await Task.sleep(for: .seconds(3))
        }
        print("BUDGET refreshDerived(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "an index rebuild burned \(cpu)s of main-thread CPU")
    }

    /// Open Quickly scores every note, alias and heading at each pause in
    /// typing — about 20,000 items here, 2,000 notes of ten headings — and it
    /// did so on the main actor (implemented.md §51.36). The control: the
    /// same scoring on the caller's actor is seen by the instrument.
    @Test func openQuicklyScoresOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-budget-oq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2_000 {
            let headings = (0..<9).map { "## Section \($0) of note \(index)" }.joined(separator: "\n\n")
            try Data("# Note \(index)\n\n\(headings)\n".utf8).write(to: root.appendingPathComponent("Note \(index).md"))
        }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        collection.refreshDerived(force: true)
        let deadline = ContinuousClock.now + .seconds(30)
        while collection.search.quickOpenResults(query: "Section 8 of note 1999", limit: 1).isEmpty,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!collection.search.quickOpenResults(query: "Section 8 of note 1999", limit: 1).isEmpty,
                "the headings were never indexed, so this measures nothing")

        let queries = ["n", "no", "not", "note 1", "sect", "section 4", "of note 19"]
        let offMain = await mainThreadCPU {
            for query in queries { _ = await collection.search.quickOpenResultsOffMain(query: query) }
        }
        let onMain = await mainThreadCPU {
            for query in queries { _ = collection.search.quickOpenResults(query: query) }
        }
        print("BUDGET openQuickly(20000 items, \(queries.count) queries): main-thread CPU \(offMain)s off, \(onMain)s on")
        #expect(offMain < Self.budget / 5, "Open Quickly burned \(offMain)s of main-thread CPU scoring")
        #expect(onMain > offMain * 3, "the instrument cannot see the scoring, so the bound above proves nothing")
    }

    /// Creating a note is an O(1) change and must cost O(1) of the user's time.
    @Test func creatingANoteNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()

        let cpu = await mainThreadCPU {
            _ = await collection.createNote(title: "Budget Probe")
        }
        print("BUDGET createNote(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "creating one note burned \(cpu)s of main-thread CPU")
    }

    /// Naming a note is a rename, and a new note opens with its title focused —
    /// so this is the path the user is on while typing.
    @Test func renamingANoteNeverBlocksTheMainActor() async throws {
        let root = try makeVault(noteCount: 2_000)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        let target = try #require(collection.note(titled: "Note 7"))

        let cpu = await mainThreadCPU {
            _ = await collection.renameNote(target, to: "Renamed While Typing")
        }
        print("BUDGET renameNote(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "renaming one note burned \(cpu)s of main-thread CPU")
    }

    /// A 2 MB note open in an editor, and the editor's copy of it with a line
    /// typed — made the way the editor makes it, from a text storage, so it is
    /// the bridged `NSString` a save is really handed.
    private func largeNoteAndAnEditorsCopy() async throws -> (EditorModel, String, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = String(repeating: "A line of the note — café, naïve, 日本語, and some prose after it.\n", count: 28_000)
        let url = dir.appendingPathComponent("Large.md")
        try Data(body.utf8).write(to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Large", fileURL: url, lastModified: Date(), fileSize: body.utf8.count))
        let copy = NSTextStorage(string: body + "Typed.\n").string
        return (editor, copy, dir)
    }

    /// Letting go of a large note — the editor's copy taken into the buffer,
    /// and saved. It compared the note with itself four times on the main
    /// actor (five, with `@Observable`'s own setter) and encoded it there as
    /// well, each a pass over a bridged string.
    ///
    /// The model's save only: no collection is listening (`onSaved` is nil),
    /// so the indexes a collection patches after each write — which still read
    /// the whole note on the main actor — are not in this number.
    @Test func savingALargeNoteBarelyTouchesTheMainActor() async throws {
        let (editor, copy, dir) = try await largeNoteAndAnEditorsCopy()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cpu = await mainThreadCPU {
            editor.adopt(copy, fromLoad: editor.loadRevision)
            await editor.save()
        }
        print("BUDGET save(2MB): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "saving a 2 MB note burned \(cpu)s of main-thread CPU")
        #expect(!editor.isDirty && editor.savedRevision == 1, "and it was not saved")
    }

    /// The control for the save: one of the comparisons it used to make, made
    /// on the main actor, is visible to the instrument — so a small number
    /// above is the save's, not the instrument's blindness.
    @Test func oneComparisonOfALargeNoteOnTheMainActorIsSeen() async throws {
        let (editor, copy, dir) = try await largeNoteAndAnEditorsCopy()
        defer { try? FileManager.default.removeItem(at: dir) }

        let buffer = editor.text
        let cpu = await mainThreadCPU {
            _ = copy != buffer
        }
        print("CONTROL compare(2MB): main-thread CPU \(cpu)s")
        #expect(cpu > 0.010, "comparing 2 MB on the main actor cost \(cpu)s, so the instrument cannot see a comparison")
    }

    /// A rename's rewrite saves one note per backlink, so the search index is
    /// patched in a burst — here for a note every other note links to, in a
    /// 2,000-note collection. Each patch copied the whole entry array while
    /// the fold scheduled by the patch before it held a snapshot of it through
    /// its wait; the fold takes its snapshot when it runs now (implemented.md
    /// §51.22).
    @Test func patchingSearchInABurstBarelyTouchesTheMainActor() async throws {
        let notes = (0..<2_000).map {
            Note(title: "Note \($0)", fileURL: URL(fileURLWithPath: "/budget/Note \($0).md"),
                 lastModified: .now, fileSize: 1)
        }
        let search = CollectionSearchModel()
        await search.load(pairs: notes.enumerated().map { index, note in
            (note, NoteIndexRecord(relativePath: "", mtime: 0, size: 1, aliases: ["Alias \(index)"],
                                   tags: ["tag\(index % 30)"], headings: [], outgoing: []))
        })

        let cpu = await mainThreadCPU {
            for note in notes {
                search.updateNote(note, headings: [], tags: ["rewritten"], aliases: [])
            }
            try? await until { search.allTags().contains("rewritten") }
        }
        print("BUDGET 2000 search patches (2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "a burst of patches burned \(cpu)s of main-thread CPU")
        #expect(search.notesTagged("rewritten").count == 2_000)
    }

    // MARK: - A save in a collection

    private static let largeBody = "# Large\n\nLinks to [[Note 3]], tagged #budget.\n\n"
        + String(repeating: "A line of the note — café, naïve, 日本語, and some prose after it.\n", count: 28_000)

    /// Wait, sleeping, until `condition` holds. A sleeping main thread burns
    /// nothing, so a wait inside a measurement counts only what it waits for.
    private func until(_ condition: () -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A 2 MB note in a 2,000-note collection whose indexes are built — link
    /// graph, search and relatedness — with an editor on it wired as the shell
    /// wires one (`onSaved` → `Collection.noteDidSave`), and the editor's copy
    /// with a line typed that adds a link and a tag.
    private func largeNoteInACollection() async throws -> (Collection, EditorModel, String, URL) {
        // 2,000 notes: the scale anything per save that walks the collection
        // shows at. Rebuilding the embed map on every save cost 23ms of main-
        // thread CPU here (26.7ms with it, 3.5ms without), and at 200 notes
        // it hid inside a total of under 5ms.
        let root = try makeVault(noteCount: 2_000)
        try Data(Self.largeBody.utf8).write(to: root.appendingPathComponent("Large.md"))
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        let unindexed = collection.derivedRevision
        collection.refreshDerived()
        try await until { collection.derivedRevision != unindexed }
        _ = await collection.relatedNotes(to: "prose", excluding: nil)

        let note = try #require(collection.note(titled: "Large"))
        let editor = EditorModel()
        editor.onSaved = { [weak collection] url, text in collection?.noteDidSave(url, text: text) }
        await editor.open(note)
        let copy = NSTextStorage(string: Self.largeBody + "Typed, with [[Note 7]] and #typed.\n").string
        return (collection, editor, copy, root)
    }

    /// A save in a collection, as the app makes one: the editor's copy
    /// written, and the collection told (`onSaved` → `noteDidSave`), which
    /// patches its link graph, search index and relatedness index from the
    /// saved text. Every patch was a pass over the whole note on the main
    /// actor — its aliases three times, its links twice, its headings, its
    /// tags, its retrieval text — and the save's own test above counts none
    /// of it, because no collection listens there.
    @Test func savingALargeNoteInACollectionBarelyTouchesTheMainActor() async throws {
        let (collection, editor, copy, root) = try await largeNoteInACollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexed = collection.derivedRevision

        let cpu = await mainThreadCPU {
            editor.adopt(copy, fromLoad: editor.loadRevision)
            await editor.save()
            // The collection's part, however it is scheduled — and the
            // aggregate rebuild the search index debounces after it.
            try? await until { collection.derivedRevision != indexed }
            try? await Task.sleep(for: .milliseconds(600))
        }
        print("BUDGET save(2MB) in a collection: main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "a save in a collection burned \(cpu)s of main-thread CPU")
        let large = try #require(collection.note(titled: "Large"))
        #expect(collection.linkGraph.outgoingLinks(for: large, in: collection.notes).map(\.title).contains("Note 7"),
                "and the link graph never heard of the save")
    }

    /// The control for the save in a collection: parsing the saved note once
    /// for the indexes and once for relatedness, on the main actor, is visible
    /// to the instrument.
    @Test func parsingALargeNoteOnTheMainActorIsSeen() async throws {
        var text = Self.largeBody + "Typed, with [[Note 7]] and #typed.\n"
        text.makeContiguousUTF8()
        let cpu = await mainThreadCPU {
            _ = CollectionIndexCache.parse(text)
            _ = RetrievalText.prepare(text)
        }
        print("CONTROL parse(2MB): main-thread CPU \(cpu)s")
        #expect(cpu > 0.010, "parsing 2 MB on the main actor cost \(cpu)s, so the instrument cannot see a parse")
    }

    // MARK: - A cloud collection's walk

    /// A provider's folder of `fileCount` notes in folders of twenty, beside
    /// the demo store's own three, and an empty cache to mirror it into.
    private func cloudFolder(fileCount: Int) async throws -> (RemoteMirror, MockRemoteStore, URL) {
        let store = MockRemoteStore(preAuthenticated: true)
        let perFolder = 20
        for index in 0..<fileCount {
            let folder = "/d\(index / perFolder)"
            if index % perFolder == 0 { try await store.createFolder(path: folder) }
            try await store.write(Data("# Note \(index)\n".utf8), to: "\(folder)/Note \(index).md")
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-budget-\(UUID().uuidString)", isDirectory: true)
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Budget cloud")
        return (mirror, store, cache)
    }

    /// Mirroring a cloud folder must not block the editor. The walk lists the
    /// provider's folders and, per file, works out its record and writes its
    /// placeholder — up to three syscalls a file — and it ran on the main
    /// thread: reached from the mirror's main-actor turn through a plain
    /// `nonisolated async` call, which runs where its caller is, and listing
    /// through a store that is itself main-actor.
    @Test func mirroringACloudFolderNeverBlocksTheMainActor() async throws {
        let (mirror, _, cache) = try await cloudFolder(fileCount: 2_000)
        defer { try? FileManager.default.removeItem(at: cache) }

        var outcome: RemoteSyncOutcome?
        let cpu = await mainThreadCPU {
            outcome = try? await mirror.syncMetadata()
        }
        print("BUDGET cloud walk(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "mirroring a cloud folder burned \(cpu)s of main-thread CPU")
        // And it did the work: every file recorded and given its placeholder.
        #expect(outcome?.isComplete == true)
        #expect(mirror.manifest.entries.values.count { !$0.isDirectory } == 2_003)
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "d99/Note 1999.md").path))
    }

    /// A provider that answers a delta with no cursor the way Dropbox and
    /// OneDrive do — with every entry under the folder — and can refuse to
    /// list folders, so a walk of it can stop short of holding a cursor.
    private final class ReplayingStore: RemoteStore, @unchecked Sendable {
        let inner: MockRemoteStore
        private let lock = NSLock()
        private var refused: Set<String> = []
        init(_ inner: MockRemoteStore) { self.inner = inner }

        func refuse(_ folders: Set<String>) { lock.withLock { refused = folders } }
        var providerName: String { inner.providerName }
        let accountID = "budget"
        var isAuthenticated: Bool { true }
        func authenticate() async throws {}
        func signOut() {}
        func list(path: String) async throws -> [RemoteEntry] {
            if lock.withLock({ refused.contains(path) }) { throw RemoteStoreError.http(403, "access_denied") }
            return try await inner.list(path: path)
        }
        func read(path: String) async throws -> Data { try await inner.read(path: path) }
        func write(_ data: Data, to path: String) async throws { try await inner.write(data, to: path) }
        func delete(path: String) async throws { try await inner.delete(path: path) }
        func move(from source: String, to destination: String) async throws { try await inner.move(from: source, to: destination) }
        func createFolder(path: String) async throws { try await inner.createFolder(path: path) }
        func latestCursor(path: String) async throws -> String? { "latest" }
        func changes(since cursor: String?, path: String) async throws -> RemoteChangeSet? {
            guard cursor == nil else { return RemoteChangeSet(cursor: cursor) }
            var everything: [RemoteEntry] = []
            var folders = [""]
            while let folder = folders.popLast() {
                for entry in try await inner.list(path: folder) {
                    everything.append(entry)
                    if entry.isDirectory { folders.append(entry.path) }
                }
            }
            return RemoteChangeSet(changed: everything, cursor: "replayed")
        }
    }

    /// A refresh before any walk has listed the whole folder — after one a
    /// folder refused, or an add cancelled — asked Dropbox and OneDrive for
    /// everything and applied every entry on the main actor, placeholders and
    /// all. It walks now, off the main actor.
    @Test func refreshingACloudFolderWithNoCursorNeverBlocksTheMainActor() async throws {
        let (mirror, mock, cache) = try await cloudFolder(fileCount: 2_000)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = ReplayingStore(mock)
        let replaying = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: mirror.displayName)
        store.refuse(Set((0..<100).map { "/d\($0)" }))
        let first = try await replaying.syncMetadata()
        #expect(!first.isComplete, "the first walk listed everything, so this tests nothing")
        store.refuse([])

        let cpu = await mainThreadCPU {
            _ = try? await replaying.refresh()
        }
        print("BUDGET cloud refresh with no cursor(2000): main-thread CPU \(cpu)s")
        #expect(cpu < Self.budget, "a refresh with no cursor burned \(cpu)s of main-thread CPU")
        #expect(replaying.manifest.entries.values.count { !$0.isDirectory } == 2_003)
    }

    /// The control: the walk's own work — the mirror's accumulator, over the
    /// same listings — run on the main actor, where the walk used to run, is
    /// seen. A small number above is the walk having moved, not the
    /// instrument missing it.
    @Test func aCloudWalksWorkOnTheMainActorIsSeen() async throws {
        let (mirror, store, cache) = try await cloudFolder(fileCount: 2_000)
        defer { try? FileManager.default.removeItem(at: cache) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let source = RemoteTreeSource(store: store, remoteRoot: "", cacheRoot: cache)
        var findings = RemoteMirror.WalkFindings(before: mirror.manifest, cacheRoot: cache, remoteRoot: "",
                                                 waiting: RemoteMirror.WaitingToGo())

        let cpu = await mainThreadCPU {
            _ = await ResumableTreeWalk.run(source: source) { batch in findings.add(batch) }
        }
        print("CONTROL cloud walk on the main actor(2000): main-thread CPU \(cpu)s")
        #expect(cpu > Self.budget, "the walk's work on the main actor cost \(cpu)s, so the instrument cannot see a walk")
        #expect(findings.found.values.count { !$0.isDirectory } == 2_003, "the control walked nothing")
    }

    // MARK: - Typing in Split mode
    #if canImport(AppKit)

    /// How much main-thread CPU one keystroke may cost, net of the harness: the
    /// Markdown pane's own share, and what anything beside it adds. A frame is
    /// 16ms.
    private static let keystrokeBudget: Double = 0.008
    /// What Split mode and the inspector may add to a keystroke, over the
    /// Markdown pane typed into — a quarter of a frame. They added at least
    /// 700ms.
    private static let keystrokeOverMarkdown: Double = 0.004

    /// A long note of the usual things — prose, headings, a list, a table,
    /// code, two diagrams, some maths and a transcluded note — about 750 KB.
    private static let splitNote: String = {
        var note = "---\ntitle: Split\ntags: [budget]\n---\n\n# A long note\n\n"
        note += "$$\\int_0^1 x^2\\,dx = \\tfrac{1}{3}$$\n\n![[Embedded]]\n\n"
        note += "```mermaid\ngraph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[One]\n  B -->|no| D[Two]\n```\n\n"
        for section in 0..<600 {
            if section % 10 == 0 { note += "## Part \(section / 10)\n\n" }
            note += "A paragraph with **bold**, _italic_, `code`, a [[Note \(section % 50)]] link and #topic\(section % 20). "
                + String(repeating: "More prose, to fill the line and wrap across the pane. ", count: 20) + "\n\n"
            if section % 25 == 0 {
                note += "- one\n- two, where $x^2$ is\n  - nested\n\n| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n\n"
                    + "```swift\nlet value = \(section)\n```\n\n"
            }
            if section % 200 == 100 { note += "![[Embedded]]\n\n" }
        }
        note += "```mermaid\nsequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi\n```\n"
        return note
    }()

    /// The note `splitNote` transcludes — drawn as a card, the height of the
    /// whole note.
    private static let embeddedNote = "# Embedded\n\n"
        + String(repeating: "A line of the embedded note, drawn into its card.\n", count: 40)

    /// Let `seconds` pass as they pass in the app: the main run loop turning,
    /// and the main actor's tasks running.
    ///
    /// Inside a `@MainActor` test those two do not happen together. An `await`
    /// parks the main thread instead of servicing its run loop, and SwiftUI
    /// updates a hosted view from the run loop; a turn of the run loop from
    /// inside the test runs no main-actor task at all — no `.task`, no timer,
    /// no hop back from `offMain` (probed: a task created before a second's
    /// turn had not started when it ended). The first version of the typing
    /// test turned the run loop only, so it counted what a keystroke's redraw
    /// did and nothing its tasks did. So: a turn, then an `await`, in small
    /// steps.
    private func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            turnRunLoop(for: 0.004)
            try? await Task.sleep(for: .milliseconds(1))
        } while Date() < deadline
    }

    /// One turn of the main run loop — synchronous, as a run loop is: it may
    /// not be run from an asynchronous context directly.
    private func turnRunLoop(for seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// `view` in a window that is never ordered front, with the environment
    /// the app gives it and a defaults suite of its own — the mode is stored
    /// there, and the app's own preferences are the person's. The test's own
    /// (`.scratchDefaults`), so nothing of it is left in them either.
    private func host(_ view: some View, mode: EditorMode) -> NSWindow {
        let defaults = ScratchDefaults.suite(mode.rawValue)
        defaults.set(mode.rawValue, forKey: EditorMode.storageKey)
        // The document store too, which Edit reads (`EditorHost`): without it
        // the environment was the app's only while the view stayed in the
        // mode the test chose, and a view that outlives its test does not
        // (`typingCost`).
        let hosting = NSHostingView(rootView: view
            .environment(IntelligenceSettings())
            .environment(AppearanceSettings())
            .environment(EditorDocumentStore())
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = window.contentView?.bounds ?? .zero
        window.layoutIfNeeded()
        return window
    }

    private func sourceTextView(in view: NSView) -> SourceTextView? {
        if let found = view as? SourceTextView { return found }
        for sub in view.subviews {
            if let found = sourceTextView(in: sub) { return found }
        }
        return nil
    }

    /// `count` characters typed at the end of the note, `interval` apart —
    /// through the text view, as a keyboard types them.
    private func type(_ count: Int, into textView: NSTextView, every interval: TimeInterval) async {
        for _ in 0..<count {
            textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            await pump(interval)
        }
    }

    /// The note open in an editor, beside the note it transcludes, which the
    /// embed provider knows.
    private func openSplitNote() async throws -> (EditorModel, CollectionEmbedProvider, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Split.md")
        try Data(Self.splitNote.utf8).write(to: url)
        let embedded = dir.appendingPathComponent("Embedded.md")
        try Data(Self.embeddedNote.utf8).write(to: embedded)
        let embeds = CollectionEmbedProvider()
        embeds.update(notes: [Note(title: "Embedded", fileURL: embedded, lastModified: Date(),
                                   fileSize: Self.embeddedNote.utf8.count)])
        let editor = EditorModel()
        await editor.open(Note(title: "Split", fileURL: url, lastModified: Date(),
                               fileSize: Self.splitNote.utf8.count))
        return (editor, embeds, dir)
    }

    /// Split mode with the inspector open on the Outline, fed as the shell
    /// feeds it.
    private struct SplitWithInspector: View {
        let editor: EditorModel
        let embeds: CollectionEmbedProvider
        let git = GitService()

        var body: some View {
            HStack(spacing: 0) {
                NoteEditorView(editor: editor, embedProvider: embeds, git: git)
                NoteInspector(editor: editor,
                              onSelectHeading: { _, _ in },
                              allTags: [], selectedTag: .constant(nil),
                              backlinks: [], outgoingLinks: [], unlinkedMentions: [],
                              onOpenNote: { _ in }, onLinkMention: { _ in },
                              onPropertiesChanged: { _, _ in },
                              fileURL: editor.note?.fileURL, git: git,
                              onRestoreRevision: { _ in }, tab: .outline)
                    .frame(width: 320)
            }
        }
    }

    /// Typing into the Markdown pane in Split mode, with the inspector open on
    /// the Outline: the source pane writes the buffer on every keystroke, and
    /// everything that follows the buffer followed it there — the whole page
    /// rendered twice, the note walked for maths and diagrams, the outline
    /// analysed, per key, on the main actor.
    @Test(.scratchDefaults) func typingInSplitModeBarelyTouchesTheMainActor() async throws {
        let floor = try await typingCost(in: .markdown) { NoteEditorView(editor: $0, embedProvider: $1, git: GitService()) }
        let split = try await typingCost(in: .split) { SplitWithInspector(editor: $0, embeds: $1) }
        print("BUDGET split typing (\(Self.splitNote.utf8.count / 1024) KB): main-thread CPU \(split.perKey)s per keystroke, \(split.settling)s settling after; Markdown alone \(floor.perKey)s per keystroke, \(floor.settling)s settling after")
        #expect(split.perKey - floor.perKey < Self.keystrokeOverMarkdown,
                "a keystroke in Split mode cost \(split.perKey)s of main-thread CPU, \(floor.perKey)s of it the Markdown pane's own")
        #expect(split.perKey < Self.keystrokeBudget, "a keystroke in Split mode cost \(split.perKey)s of main-thread CPU")
        #expect(split.settling < Self.budget, "catching up after typing cost \(split.settling)s of main-thread CPU")
        // Preview follows the typing, and at a pause: no page per key, and one
        // once it stops.
        #expect(split.pagesWhileTyping == 0, "Preview was handed \(split.pagesWhileTyping) pages while typing")
        #expect(split.pagesAfter == 1, "Preview was handed \(split.pagesAfter) pages once typing paused")
    }

    /// Main-thread CPU per keystroke while typing 20 characters into the note
    /// in `view`, shown in `mode`, and while it catches up afterwards — and
    /// the pages Preview was handed in each (`EditorProbe`'s "load" lines).
    ///
    /// **Net of the harness.** Turning the run loop and awaiting in small
    /// steps (`pump`) costs the main thread something of its own — 73ms in
    /// two idle seconds, measured — so the same turns are made first with
    /// nothing typed, and taken off.
    private func typingCost(in mode: EditorMode, _ view: (EditorModel, CollectionEmbedProvider) -> some View) async throws
        -> (perKey: Double, settling: Double, pagesWhileTyping: Int, pagesAfter: Int) {
        let (editor, embeds, dir) = try await openSplitNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        var pages = 0
        EditorProbe.listener = { line in if line.hasPrefix("load ") { pages += 1 } }
        defer { EditorProbe.listener = nil }
        let window = host(view(editor, embeds), mode: mode)
        // The view leaves the window on every way out, so no layout of the
        // window reaches it again. It is not released for all that — it was
        // still alive after a second of the run loop turning — which is why
        // `host` gives it the app's whole environment: a view that outlives
        // its test hears the test's defaults cleared, falls back to Edit, and
        // asked for an `EditorDocumentStore` this window never had; the test
        // host crashed after the suite had passed (implemented.md §51.31).
        defer { window.contentView = nil; window.close() }
        await pump(3)
        // Quiet before anything is measured: the first page is built in two
        // steps (plain, then whole), and the whole one draws the transcluded
        // card on the main actor the first time. A baseline taken while that
        // was still going subtracted it from the typing, and the net came out
        // at nothing.
        var quiet = 0.0, seen = pages
        for _ in 0..<40 where quiet < 1 {
            await pump(0.25)
            if pages == seen { quiet += 0.25 } else { seen = pages; quiet = 0 }
        }
        let content = try #require(window.contentView)
        let textView = try #require(sourceTextView(in: content), "no Markdown pane: this is not \(mode)")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        let idleTyping = await mainThreadCPU { for _ in 0..<20 { await pump(0.08) } }
        let idleSettling = await mainThreadCPU { await pump(2) }

        let before = editor.textGeneration
        let pagesBefore = pages
        let typing = await mainThreadCPU { await type(20, into: textView, every: 0.08) }
        let pagesWhileTyping = pages - pagesBefore
        let settling = await mainThreadCPU { await pump(2) }
        #expect(editor.textGeneration == before + 20, "the keystrokes never reached the buffer")
        #expect(editor.settledText.version == editor.textVersion, "typing never settled")
        // The harness alone costs ~0.1s in two idle seconds; much more, and
        // something else was running while the baseline was taken, so the net
        // figures below would be a subtraction of it.
        #expect(idleSettling < 0.15, "the window was not quiet before typing: \(idleSettling)s in two idle seconds")
        print("HARNESS \(mode): \(idleTyping / 20)s a keystroke's wait, \(idleSettling)s two idle seconds")
        return (max(0, typing - idleTyping) / 20, max(0, settling - idleSettling),
                pagesWhileTyping, pages - pagesBefore - pagesWhileTyping)
    }

    /// A pane whose body renders the page from the buffer, as Preview's did.
    private struct RenderingEveryKey: View {
        let editor: EditorModel
        var body: some View {
            HStack(spacing: 0) {
                SourceEditor(text: Binding(get: { editor.text }, set: { editor.text = $0 }),
                             fontSize: 13, editorID: editor.editorID)
                GFMPreview(markdown: editor.text)
            }
        }
    }

    /// The control: the same keystrokes, the same harness, into a pane that
    /// renders the page per key. A small number above is the pane's, not the
    /// harness never letting SwiftUI redraw — and no page while typing is
    /// Preview's, not the count being unable to see one.
    @Test(.scratchDefaults) func typingIntoAPaneThatRendersEveryKeyIsSeen() async throws {
        let cost = try await typingCost(in: .split) { editor, _ in RenderingEveryKey(editor: editor) }
        print("CONTROL render-every-key typing: main-thread CPU \(cost.perKey)s per keystroke, \(cost.pagesWhileTyping) pages while typing")
        #expect(cost.perKey > 0.010, "a pane rendering the page per key cost \(cost.perKey)s a keystroke, so the harness cannot see a redraw")
        #expect(cost.pagesWhileTyping >= 10, "a pane rendering the page per key was handed \(cost.pagesWhileTyping) pages, so the count cannot see a page")
    }
    #endif
}

/// Thread-safe worst-case accumulator for the probe.
private final class LatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func record(_ latency: Duration) {
        lock.lock()
        if latency > value { value = latency }
        lock.unlock()
    }

    var worst: Duration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

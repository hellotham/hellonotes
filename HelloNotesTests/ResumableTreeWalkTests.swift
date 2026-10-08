//
//  ResumableTreeWalkTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 15/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes


/// The walk's contract. Every one of these is a property the old
/// `FileManager.enumerator` could not have: it returned only when finished,
/// could not be checkpointed, and threw away everything on cancellation.
struct ResumableTreeWalkTests {

    // MARK: Fixtures

    /// A tree `breadth` wide and `depth` deep, with `notesPerDirectory` notes in
    /// each directory.
    @discardableResult
    private static func makeTree(at root: URL, breadth: Int, depth: Int,
                                 notesPerDirectory: Int) throws -> Int {
        var directories = 0
        func build(_ url: URL, _ remaining: Int) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directories += 1
            for n in 0..<notesPerDirectory {
                try Data("# note \(n)".utf8).write(to: url.appendingPathComponent("Note\(n).md"))
            }
            guard remaining > 0 else { return }
            for b in 0..<breadth {
                try build(url.appendingPathComponent("dir\(b)"), remaining - 1)
            }
        }
        try build(root, depth)
        return directories
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-walk-\(UUID().uuidString)", isDirectory: true)
    }

    private static func collect(_ source: some TreeSource,
                                resuming checkpoint: WalkCheckpoint? = nil)
        async -> (result: WalkResult, children: [TreeChild]) {
        var seen: [TreeChild] = []
        let result = await ResumableTreeWalk.run(source: source, resuming: checkpoint) { batch in
            seen += batch.children
        }
        return (result, seen)
    }

    // MARK: Basics

    @Test func aCompleteWalkFindsEverythingAndSaysSo() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try Self.makeTree(at: root, breadth: 2, depth: 2, notesPerDirectory: 3)

        let (result, children) = await Self.collect(LocalTreeSource(root: root))

        #expect(result.isComplete)
        #expect(result.issues.isEmpty)
        #expect(result.checkpoint == nil)
        #expect(result.progress.directoriesVisited == directories)
        #expect(children.filter(\.isMarkdown).count == directories * 3)
    }

    /// Results arrive as the walk proceeds rather than in one lump at the end —
    /// which is what lets a big collection fill in instead of appearing to hang.
    @Test func resultsArriveIncrementally() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTree(at: root, breadth: 3, depth: 2, notesPerDirectory: 1)

        var batches = 0
        var sawChildrenBeforeTheEnd = false
        _ = await ResumableTreeWalk.run(source: LocalTreeSource(root: root)) { batch in
            batches += 1
            if batches == 1, !batch.children.isEmpty { sawChildrenBeforeTheEnd = true }
        }
        #expect(batches > 1)
        #expect(sawChildrenBeforeTheEnd)
    }

    /// Breadth-first: the top level is reported before anything nested, so a tree
    /// fills from the top the way a person reads it.
    @Test func theWalkIsBreadthFirst() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTree(at: root, breadth: 2, depth: 2, notesPerDirectory: 0)

        var order: [String] = []
        _ = await ResumableTreeWalk.run(source: LocalTreeSource(root: root)) { batch in
            order.append(batch.directory)
        }
        #expect(order.first == "")
        // Every depth-1 directory precedes every depth-2 one.
        let depths = order.map { $0.isEmpty ? 0 : $0.split(separator: "/").count }
        #expect(depths == depths.sorted())
    }

    // MARK: Cancellation and resumption

    /// Cancelling keeps what was found and hands back a checkpoint. The old walk
    /// returned `([], [], [])` — everything discarded.
    @Test func cancellingKeepsResultsAndYieldsACheckpoint() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTree(at: root, breadth: 4, depth: 3, notesPerDirectory: 2)

        let collector = Collector()
        let task = Task {
            await ResumableTreeWalk.run(source: LocalTreeSource(root: root)) { batch in
                collector.add(batch.children)
                // Stop once there is definitely more tree left to see.
                if collector.batches == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.value

        #expect(result.isComplete == false)
        let checkpoint = try #require(result.checkpoint)
        #expect(!checkpoint.isEmpty, "there must be somewhere to resume from")
        #expect(collector.count > 0, "what was walked before cancelling is kept")
    }

    /// Resuming finishes the job, and finishes it *once* — no directory is
    /// walked twice, which on a cloud tree would be a second round of requests.
    @Test func resumingCompletesTheWalkWithoutRepeatingItself() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try Self.makeTree(at: root, breadth: 3, depth: 2, notesPerDirectory: 2)
        let source = LocalTreeSource(root: root)

        // Walk until cancelled.
        let collector = Collector()
        let first = await Task {
            await ResumableTreeWalk.run(source: source) { batch in
                collector.add(batch.children)
                if collector.batches == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }.value
        let checkpoint = try #require(first.checkpoint)

        // Resume from the checkpoint.
        var visitedAfter: [String] = []
        let second = await ResumableTreeWalk.run(source: source, resuming: checkpoint) { batch in
            visitedAfter.append(batch.directory)
            collector.add(batch.children)
        }

        #expect(second.isComplete)
        #expect(second.progress.directoriesVisited == directories,
                "the resumed walk counts the whole tree, not just its own share")
        #expect(Set(visitedAfter).count == visitedAfter.count, "no directory walked twice")
        let notes = collector.children.filter(\.isMarkdown).count
        #expect(notes == directories * 2, "every note found exactly once across both passes")
    }

    // MARK: Symlinked folders

    /// A vault holding a link to a folder outside it, and every kind of link
    /// that must not be followed: back to the vault, into it (its notes would
    /// be two notes for one file), above it, and a loop made of two links.
    private static func makeLinkedFolders() throws -> (vault: URL, base: URL) {
        let base = temporaryRoot()
        let fm = FileManager.default
        let vault = base.appending(path: "vault", directoryHint: .isDirectory)
        let ext = base.appending(path: "ext", directoryHint: .isDirectory)
        let ext2 = base.appending(path: "ext2", directoryHint: .isDirectory)
        for folder in [vault.appending(path: "sub"), ext.appending(path: "deeper"), ext2] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for (url, text) in [(vault.appending(path: "Top.md"), "# Top"), (vault.appending(path: "sub/In.md"), "# In"),
                            (ext.appending(path: "Ext.md"), "# Ext"), (ext.appending(path: "deeper/Deep.md"), "# Deep"),
                            (ext2.appending(path: "E2.md"), "# E2")] {
            try Data(text.utf8).write(to: url)
        }
        try fm.createSymbolicLink(at: vault.appending(path: "Shared"), withDestinationURL: ext)
        try fm.createSymbolicLink(at: vault.appending(path: "Loop"), withDestinationURL: vault)
        try fm.createSymbolicLink(at: vault.appending(path: "Dup"), withDestinationURL: vault.appending(path: "sub"))
        try fm.createSymbolicLink(at: ext.appending(path: "up"), withDestinationURL: base)
        try fm.createSymbolicLink(at: ext.appending(path: "l1"), withDestinationURL: ext2)
        try fm.createSymbolicLink(at: ext2.appending(path: "l2"), withDestinationURL: ext)
        return (vault, base)
    }

    private static let expectedLinkedNotes: Set<String> = [
        "Top.md", "sub/In.md", "Shared/Ext.md", "Shared/deeper/Deep.md", "Shared/l1/E2.md",
    ]

    private static func relativeNotes(_ children: [TreeChild], in vault: URL) -> [String] {
        let prefix = vault.standardizedFileURL.path + "/"
        return children.filter(\.isMarkdown).map { String($0.url.standardizedFileURL.path.dropFirst(prefix.count)) }
    }

    /// **A symlinked subfolder is walked** — once, where it is linked — and
    /// a link that would loop, or walk the vault twice, is not followed. It
    /// reported neither `isDirectory` nor `isRegularFile` and was skipped, so
    /// its notes never entered the index (implemented.md §51.36).
    @Test func aSymlinkedSubfolderIsWalkedAndALoopIsNot() async throws {
        let (vault, base) = try Self.makeLinkedFolders()
        defer { try? FileManager.default.removeItem(at: base) }

        let walk = Task { await Self.collect(LocalTreeSource(root: vault)) }
        let guardrail = Task { try await Task.sleep(for: .seconds(20)); walk.cancel() }
        let (result, children) = await walk.value
        guardrail.cancel()

        let notes = Self.relativeNotes(children, in: vault)
        #expect(result.isComplete, "the walk did not finish — a link looped")
        #expect(Set(notes) == Self.expectedLinkedNotes, "\(notes.sorted())")
        #expect(notes.count == Set(notes).count, "a note was walked twice: \(notes.sorted())")
    }

    /// The folders a walk is inside are named by the path it is listing, link
    /// by link, so a resumed walk refuses the same loops without remembering
    /// anything.
    @Test func aResumedWalkStillRefusesALoop() async throws {
        let (vault, base) = try Self.makeLinkedFolders()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = LocalTreeSource(root: vault)

        let collector = Collector()
        let first = await Task {
            await ResumableTreeWalk.run(source: source) { batch in
                collector.add(batch.children)
                if collector.batches == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }.value
        let checkpoint = try #require(first.checkpoint)
        let walk = Task {
            await ResumableTreeWalk.run(source: source, resuming: checkpoint) { batch in collector.add(batch.children) }
        }
        let guardrail = Task { try await Task.sleep(for: .seconds(20)); walk.cancel() }
        let second = await walk.value
        guardrail.cancel()

        let notes = Self.relativeNotes(collector.children, in: vault)
        #expect(second.isComplete)
        #expect(Set(notes) == Self.expectedLinkedNotes, "\(notes.sorted())")
    }

    // MARK: Failure isolation

    @Test func anUnreadableDirectoryCostsItsSubtreeNotTheWalk() async throws {
        let root = Self.temporaryRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.appendingPathComponent("dir0").path)
            try? FileManager.default.removeItem(at: root)
        }
        try Self.makeTree(at: root, breadth: 2, depth: 1, notesPerDirectory: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: root.appendingPathComponent("dir0").path)

        let (result, children) = await Self.collect(LocalTreeSource(root: root))

        #expect(result.issues.map(\.path) == ["dir0"])
        #expect(result.isComplete == false, "a walk that skipped a folder has not seen the tree")
        #expect(children.filter(\.isMarkdown).count == 4, "root + dir1 still found")
    }

    /// An unreadable *root* is not an empty tree, and the walk must not present
    /// it as one.
    @Test func anUnreadableRootIsReportedRatherThanWalked() async {
        let root = Self.temporaryRoot()   // never created
        let (result, children) = await Self.collect(LocalTreeSource(root: root))

        #expect(result.unavailable == .missing)
        #expect(result.isComplete == false)
        #expect(children.isEmpty)
    }

    // MARK: Options

    @Test func packagesAreListedButNeverDescendedInto() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("Doc.rtfd")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("# hidden".utf8).write(to: bundle.appendingPathComponent("Inside.md"))

        let (result, children) = await Self.collect(LocalTreeSource(root: root))

        #expect(result.isComplete)
        #expect(children.contains { $0.url.lastPathComponent == "Doc.rtfd" })
        #expect(!children.contains { $0.url.lastPathComponent == "Inside.md" },
                "a package is one item, not a folder to walk")
    }

    /// Excluding non-note files happens *during* the listing. On a folder of a
    /// hundred thousand documents the difference between not collecting them and
    /// collecting-then-filtering is the whole point.
    @Test func nonNoteFilesCanBeExcludedAtTheSource() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# note".utf8).write(to: root.appendingPathComponent("Note.md"))
        try Data("pdf".utf8).write(to: root.appendingPathComponent("Resume.pdf"))

        let (_, withFiles) = await Self.collect(LocalTreeSource(root: root, includesNonNoteFiles: true))
        #expect(withFiles.count == 2)

        let (_, notesOnly) = await Self.collect(LocalTreeSource(root: root, includesNonNoteFiles: false))
        #expect(notesOnly.count == 1)
        #expect(notesOnly.first?.isMarkdown == true)
    }

    // MARK: Checkpoint storage

    @Test func checkpointsSurviveARoundTripAndAreKeyedStably() throws {
        let id = "/some/collection/\(UUID().uuidString)"
        defer { WalkCheckpointStore.remove(for: id) }
        let checkpoint = WalkCheckpoint(frontier: ["a", "a/b"], directoriesVisited: 7,
                                        itemsSeen: 42, previousTotalDirectories: 99)
        WalkCheckpointStore.save(checkpoint, for: id)
        #expect(WalkCheckpointStore.load(for: id) == checkpoint)

        WalkCheckpointStore.remove(for: id)
        #expect(WalkCheckpointStore.load(for: id) == nil)
    }

    /// The previous run's size is what turns the second scan's spinner into a
    /// real percentage.
    @Test func aKnownTotalMakesProgressDeterminate() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = try Self.makeTree(at: root, breadth: 2, depth: 2, notesPerDirectory: 0)

        var fractions: [Double] = []
        _ = await ResumableTreeWalk.run(
            source: LocalTreeSource(root: root),
            resuming: WalkCheckpoint(frontier: [""], directoriesVisited: 0, itemsSeen: 0,
                                     previousTotalDirectories: directories)
        ) { batch in
            if let f = batch.progress.fraction { fractions.append(f) }
        }

        #expect(fractions.count == directories)
        #expect(fractions == fractions.sorted(), "a progress bar must not go backwards")
        #expect(fractions.last == 1.0)
        #expect(fractions.allSatisfy { $0 <= 1.0 })
    }

    /// A tree that grew since the last complete walk must not push the bar past
    /// the end — a bar that reaches 100% and keeps going is worse than none.
    @Test func progressIsClampedWhenTheTreeHasGrown() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTree(at: root, breadth: 2, depth: 2, notesPerDirectory: 0)

        var fractions: [Double] = []
        _ = await ResumableTreeWalk.run(
            source: LocalTreeSource(root: root),
            resuming: WalkCheckpoint(frontier: [""], directoriesVisited: 0, itemsSeen: 0,
                                     previousTotalDirectories: 2)   // stale, far too small
        ) { batch in
            if let f = batch.progress.fraction { fractions.append(f) }
        }
        #expect(fractions.allSatisfy { $0 <= 1.0 })
    }
}

/// Not a correctness test — a guard against the frontier walk being
/// dramatically slower than the enumerator it replaces, on the shape and scale
/// of tree people actually have.
@MainActor
struct TreeWalkBenchmark {

    @Test func theWalkIsCompetitiveWithTheEnumeratorOnARealisticVault() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // ~1,111 directories / ~2,222 notes — the scale of the author's real vault.
        var directories = 0
        func build(_ url: URL, _ remaining: Int) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directories += 1
            for n in 0..<2 {
                try Data("# n".utf8).write(to: url.appendingPathComponent("N\(n).md"))
            }
            guard remaining > 0 else { return }
            for b in 0..<10 { try build(url.appendingPathComponent("d\(b)"), remaining - 1) }
        }
        try build(root, 3)

        // Both timed where the app runs them — off the main actor, on the
        // shared pool — so the two are measured under the same conditions. The
        // enumerator was timed on this suite's main actor and the walk on the
        // pool, and in a full parallel run the pool is busy: 3.05 s against
        // 0.27 s, a comparison of two places rather than two walks.
        // `enumerate` returns nil only when its task was cancelled — not the
        // case here, and a benchmark comparing against nothing would silently
        // pass.
        let (enumerated, enumeratorSeconds) = await Self.enumerate(root)
        let old = try #require(enumerated)
        let (result, children, walkSeconds) = await Self.walk(root)
        let notesFound = children.filter(\.isMarkdown).count
        let directoriesFound = children.filter(\.isDirectory).count

        print("BENCH dirs=\(directories) notes=\(old.notes.count) "
              + "enumerator=\(String(format: "%.3f", enumeratorSeconds))s "
              + "walk=\(String(format: "%.3f", walkSeconds))s "
              + "ratio=\(String(format: "%.2f", walkSeconds / max(enumeratorSeconds, 0.0001)))")

        // Same tree, same answer as the enumerator it replaces.
        #expect(result.isComplete)
        #expect(result.progress.directoriesVisited == directories)
        #expect(notesFound == old.notes.count)
        #expect(directoriesFound == old.folders.count)

        // The guard: a frontier walk issues the same syscalls, so anything beyond
        // a small multiple means something has gone quadratic.
        #expect(walkSeconds < max(enumeratorSeconds * 4, 0.5),
                "walk \(walkSeconds)s vs enumerator \(enumeratorSeconds)s")
    }

    /// The walk as the app runs it: from no actor, its batches gathered under
    /// a lock — the scan, the mirror and the size estimate all call it so.
    /// Gathered by a closure written on this suite's main actor, every
    /// directory's batch hopped to the main actor and back once `run` became
    /// `@concurrent`, a cost no caller pays; alone it was 15% of the time
    /// measured, and in a full parallel run, queued behind every other
    /// main-actor test, it was most of eight seconds.
    @concurrent
    private nonisolated static func walk(_ root: URL) async -> (WalkResult, [TreeChild], TimeInterval) {
        let gathered = Collector()
        let start = Date()
        let result = await ResumableTreeWalk.run(source: LocalTreeSource(root: root)) { batch in
            gathered.add(batch.children)
        }
        return (result, gathered.children, Date().timeIntervalSince(start))
    }

    /// The enumerator the walk replaced, timed in the same place.
    @concurrent
    private nonisolated static func enumerate(_ root: URL) async
        -> ((notes: [Note], attachments: [CollectionFile], folders: [URL])?, TimeInterval) {
        let start = Date()
        let result = Collection.enumerate(root)
        return (result, Date().timeIntervalSince(start))
    }
}

/// Gathers batches from the walk's executor.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TreeChild] = []
    private(set) var batches = 0

    func add(_ children: [TreeChild]) {
        lock.lock(); defer { lock.unlock() }
        storage += children
        batches += 1
    }
    var children: [TreeChild] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { children.count }
}


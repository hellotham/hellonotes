//
//  ResumableTreeWalkTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 15/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

#if os(macOS)

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

        var start = Date()
        let old = Collection.enumerate(root)
        let enumeratorSeconds = Date().timeIntervalSince(start)

        var notesFound = 0
        var directoriesFound = 0
        start = Date()
        let result = await ResumableTreeWalk.run(source: LocalTreeSource(root: root)) { batch in
            notesFound += batch.children.filter(\.isMarkdown).count
            directoriesFound += batch.children.filter(\.isDirectory).count
        }
        let walkSeconds = Date().timeIntervalSince(start)

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

#endif

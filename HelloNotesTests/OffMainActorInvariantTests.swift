//
//  OffMainActorInvariantTests.swift
//  HelloNotesTests
//
//  Created by Chris Tham on 18/8/2026.
//

import Testing
import Foundation
@testable import HelloNotes

/// The golden rule, enforced where it actually broke.
///
/// > The main editor loop can never be blocked for any reason — folder scans,
/// > search, index rebuild, AI, anything.
///
/// The rule was broken not by code that did the wrong thing, but by a *build
/// setting*: the app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// so every unannotated type is `@MainActor`. `LocalTreeSource` was one, which
/// meant `await source.children(of:)` hopped the folder walk onto the main
/// actor from inside the very `Task.detached` written to keep it off. On the
/// reported iCloud vault each listing was then a synchronous XPC round-trip to
/// `fileproviderd` on the main thread, and the editor froze for five seconds at
/// a time.
///
/// Nothing in the source looked wrong, which is why two rounds of fixes reasoned
/// their way to the wrong answer. So the guarantee is checked by the compiler
/// here rather than trusted: **if any of these types regains main-actor
/// isolation, this file stops building.**
@Suite
struct OffMainActorInvariantTests {

    /// Compile-time invariant. The body is `@concurrent` and `nonisolated`, so
    /// every call it makes must be too. A regression is a build failure, which
    /// is the only kind of check that cannot be forgotten, skipped or flaked.
    /// Bookmarks are resolved and minted off the main actor — at launch, by
    /// Try Again and by Relocate (implemented.md §51.36). If `Bookmark` regains
    /// main-actor isolation, this stops building.
    @concurrent
    private func bookmarksFromANonisolatedContext(_ url: URL) async -> URL? {
        guard let data = Bookmark.data(for: url) else { return nil }
        return Bookmark.resolveRefreshing(data, mounting: false)?.url
    }

    @concurrent
    private func walkFromANonisolatedContext(root: URL) async -> WalkResult {
        let source = LocalTreeSource(root: root)
        return await ResumableTreeWalk.run(source: source) { _ in }
    }

    /// Runtime invariant: the walk's callbacks really do run off the main
    /// thread. The probe lives in the *test's* closure, never in the app, so it
    /// cannot drag the code it measures onto the main actor — which is exactly
    /// how an earlier probe manufactured the bug it was looking for.
    @Test func theWalkNeverRunsOnTheMainThread() async throws {
        let root = try makeSmallVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let sawMainThread = Mutex(false)
        let source = LocalTreeSource(root: root)
        let result = await ResumableTreeWalk.run(source: source) { _ in
            if Thread.isMainThread { sawMainThread.set(true) }
        }

        #expect(result.isComplete)
        #expect(sawMainThread.get() == false,
                "a folder walk ran on the main thread; on a cloud vault each listing is a blocking XPC call")
    }

    /// Called from the main actor, the walk still walks off it.
    ///
    /// `run` was a plain `nonisolated async` function, and under approachable
    /// concurrency such a function runs wherever its caller is: the cloud walk
    /// awaited it from the mirror's main-actor turn and so listed every folder
    /// on the main thread, until §51.34 moved the caller. The test above calls
    /// from a nonisolated context, the one place that could not show it.
    /// `@concurrent` makes the walk's executor the global one whoever calls it,
    /// so the next caller written from main-actor code cannot bring it back.
    ///
    /// Probed in the *listing*, which is the walk's own work. The batches are
    /// handed to a closure the caller wrote, and one written on the main actor
    /// is the main actor's — that is where a caller wants its batches.
    @MainActor @Test func aWalkCalledFromTheMainActorWalksOffIt() async throws {
        let root = try makeSmallVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = ListingProbe(base: LocalTreeSource(root: root))
        let result = await ResumableTreeWalk.run(source: source) { _ in }
        #expect(result.isComplete)
        #expect(source.listings.get() > 0)
        #expect(source.sawMainThread.get() == false, "a walk called from the main actor listed folders on it")
    }

    /// A source that remembers whether any listing ran on the main thread.
    private struct ListingProbe: TreeSource {
        let base: LocalTreeSource
        let sawMainThread = Mutex(false)
        let listings = Mutex(0)

        func unavailability() -> CollectionState.UnavailableReason? { base.unavailability() }

        func children(of directory: String) async throws -> DirectoryListing {
            if Thread.isMainThread { sawMainThread.set(true) }
            listings.set(listings.get() + 1)
            return try await base.children(of: directory)
        }
    }

    /// The editor's write must not be on the main thread either — it ends in a
    /// coordinated write, which blocks for as long as a File Provider takes.
    @Test func theCoordinatedWriteNeverRunsOnTheMainThread() async throws {
        let root = try makeSmallVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Written.md")

        let onMain = await offMain { () -> Bool in
            try? FileIO.write(Data("# Written\n".utf8), to: url)
            return Thread.isMainThread
        }
        #expect(onMain == false, "offMain ran its body on the main thread")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func makeSmallVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<12 {
            try Data("# Note \(index)\n".utf8)
                .write(to: root.appendingPathComponent("Note \(index).md"))
        }
        return root
    }
}

/// Minimal lock-box so the walk's `@Sendable` callback can report back.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

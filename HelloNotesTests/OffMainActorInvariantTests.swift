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

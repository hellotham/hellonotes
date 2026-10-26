//
//  GitThread.swift
//  HelloNotes
//
//  libgit2's network work — a clone, a push, a fetch — on a thread of its own.
//
//  Every libgit2 call blocks its thread, and a network one for as long as the
//  network takes: a clone of a big repository for minutes, a push to a host
//  that accepts and never answers until the connection ends. They ran in
//  `Task.detached`, which is the concurrency pool — a thread a core, through
//  which every sleeping task in the process wakes, the main actor's too
//  (implemented.md §51.62). SwiftGitX says as much over its own clone:
//  "libgit2 calls block Swift's cooperative threads". On a thread of its own
//  a call the network holds up holds up nothing else (implemented.md §51.66).
//
//  Off a task, `Task.isCancelled` has no task to ask — and that is how Stop
//  reached libgit2: its progress callbacks answered "stop" once the task was
//  cancelled. So the cancel of the task that waits sets a flag (`GitCancel`),
//  and the callbacks read it through their payload.
//

import Foundation
import Synchronization

/// Whether the task waiting on a libgit2 call was cancelled: set by its
/// cancel, read by libgit2's callbacks on a thread that has no task to ask
/// (`GitThread`).
nonisolated final class GitCancel: Sendable {
    private let flag = Atomic(false)

    func set() { flag.store(true, ordering: .relaxed) }
    var isSet: Bool { flag.load(ordering: .relaxed) }

    /// The flag as a callback's payload — unretained: whoever made the call
    /// keeps the flag alive for as long as the call lasts.
    var payload: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Whether the flag behind a callback's `payload` is set.
    static func isSet(_ payload: UnsafeMutableRawPointer?) -> Bool {
        guard let payload else { return false }
        return Unmanaged<GitCancel>.fromOpaque(payload).takeUnretainedValue().isSet
    }
}

nonisolated enum GitThread {
    /// The threads' names — what a stack sample shows, and what a test hears.
    static let push = "com.hellotham.HelloNotes.git.push"
    static let fetch = "com.hellotham.HelloNotes.git.fetch"
    static let clone = "com.hellotham.HelloNotes.git.clone"
    static let create = "com.hellotham.HelloNotes.git.create"

    /// Run `body` — libgit2 work that blocks its thread — on a thread of its
    /// own named `name`, and wait for it without holding a thread of the
    /// pool. A cancel of the waiting task sets `body`'s flag: the work stops
    /// at libgit2's next callback, and this returns once it has stopped, never
    /// before — a clone's cleanup must not run under a clone still writing.
    static func run<T: Sendable>(_ name: String, for url: URL,
                                 _ body: @escaping @Sendable (GitCancel) throws -> T) async throws -> T {
        let cancel = GitCancel()
        let probe = probes.withLock { $0[url.path] }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread {
                    probe?(Thread.current.name ?? "")
                    continuation.resume(with: Result { try body(cancel) })
                }
                thread.name = name
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancel.set()
        }
    }

    /// Told, for the folder a run is for, the name of the thread it ran on —
    /// a test's way to see which work went where, which no timing can show.
    /// Keyed by path, so tests running at once hear only their own; empty
    /// outside tests.
    static let probes = Mutex<[String: @Sendable (_ threadName: String) -> Void]>([:])
}

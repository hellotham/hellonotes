//
//  ProviderHold.swift
//  HelloNotesTests
//
//  A file held the way a cloud provider holds one it is still writing.
//

import Foundation

/// A file held the way a cloud provider holds one it is still writing: under a
/// coordinated write, which a coordinated read — `FileIO.readData` — waits for,
/// and so does a coordinated write. Held until the test lets it go, and only
/// then. It used to let go by itself ten seconds after it was made, so that a
/// save queued behind it would finish and fail the test rather than hang it;
/// and on CI's runner, every test in the target sharing the main actor, the
/// test had not reached its save by then — the note loaded, the save wrote
/// into a loaded note, and two tests failed with the app right
/// (implemented.md §51.62). The step that may queue is waited for with the
/// test's patience instead (`UnloadedNoteTests.finishesWhileHeld`), and the
/// hold let go after.
///
/// `breaker` is for the one kind of test whose failure no step of its own
/// could end: a process stopped outright, every sleeping task with it
/// (`HeldFileTests`). The hold then lets go by itself that long after it was
/// made, on a thread of its own that no stopped pool can hold up, and
/// `isLetGo` says it has — by the test, or by the breaker.
nonisolated final class ProviderHold: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false
    private var letGo = false

    init(_ url: URL, breaker: DispatchTimeInterval? = nil) {
        let held = DispatchSemaphore(value: 0)
        Thread { [done, lock] in
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                             error: &error) { _ in
                held.signal()
                if let breaker { _ = done.wait(timeout: .now() + breaker) } else { done.wait() }
                lock.lock()
                self.letGo = true
                lock.unlock()
            }
            if error != nil { held.signal() }
        }.start()
        held.wait()
    }

    /// Whether the file has been let go — by `release`, or by the breaker.
    var isLetGo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return letGo
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        done.signal()
    }
}

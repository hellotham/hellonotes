//
//  Deadline.swift
//  HelloNotes
//
//  Waiting for something for no longer than a deadline — kept by a clock that
//  nothing being waited for can hold up.
//
//  A wait that reads its clock between steps is only as bounded as its
//  slowest step: one call to a file provider that never came back held the
//  "Downloading … from the cloud" banner up for good (implemented.md §51.51).
//  So the waiter is answered by whichever comes first, the work or a timer on
//  a queue of its own, and the work, if it loses, goes on unwaited for
//  (§51.52).
//

import Foundation

/// One answer for one waiter, from whichever of several gives it first; the
/// rest are dropped. Given before the waiter is there, it is kept for it.
nonisolated final class OneAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    var isGiven: Bool { lock.withLock { value != nil } }

    /// Wait for the answer — and `false` if it has been given already, in
    /// which case the waiter has it now and there is nothing left to start.
    @discardableResult
    func expect(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        if let value {
            lock.unlock()
            continuation.resume(returning: value)
            return false
        }
        waiter = continuation
        lock.unlock()
        return true
    }

    func give(_ answer: Value) {
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = answer
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: answer)
    }
}

extension Duration {
    /// The same span, for GCD.
    nonisolated var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}

/// Run `work` on the main actor and wait for it no longer than `patience`:
/// `true` if it finished in time.
///
/// Past the deadline it goes on, unwaited for, and what it does when it ends
/// is its own affair — a download allowed to finish is found as any change on
/// disk is. Cancelling the wait stops the waiting, not the work. The deadline
/// is kept on a queue of its own (`FileIO.deadlines`).
@MainActor
func finishes(within patience: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
    let answer = OneAnswer<Bool>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            guard answer.expect(continuation) else { return }
            Task { @MainActor in
                await work()
                answer.give(true)
            }
            FileIO.deadlines.asyncAfter(deadline: .now() + patience.dispatchInterval) { answer.give(false) }
        }
    } onCancel: {
        answer.give(false)
    }
}

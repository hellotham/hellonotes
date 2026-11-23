//
//  WorkHold.swift
//  HelloNotes
//
//  A test's hold on one piece of a collection's own work — a save's parse, a
//  rebuild, the relatedness index's build — so that a race is staged exactly.
//

import Foundation
import Synchronization

/// A place where a test can stop one piece of a collection's work, and let it
/// go.
///
/// The work held here runs off the main actor and lands on it, and the races
/// between such work — a save still being parsed when a newer one lands, a
/// rebuild still out when a save is patched in, the relatedness index still
/// building when a note is saved — were staged by making the work slow: a
/// note of two to eight megabytes, two hundred notes changed on disk. That
/// made a race likely and never certain. On a busy runner, or a one-thread
/// pool (`TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), the race could
/// be over before it was looked at: a test that said "this tests nothing",
/// or one that passed for that reason without saying so (implemented.md
/// §51.81). A hold is exact. The work waits at it — asleep, holding no
/// thread — until the test lets it go.
///
/// Keyed by kind and path — a note's path for a save, the collection's
/// folder for the rest — so tests running at once hold only their own work.
/// Each hold armed is taken by the next piece of that work for that path, in
/// the order armed: armed once, a note's first save is held and its second
/// is not. Empty outside tests, so the work pays one look in an empty
/// dictionary.
nonisolated final class WorkHold: Sendable {
    enum Kind: Hashable, Sendable {
        /// A save, parsed and not yet applied to the indexes
        /// (`Collection.indexSaved`).
        case saveParse
        /// A rebuild, its notes read and nothing yet loaded
        /// (`Collection.refreshDerived`).
        case rebuild
        /// The relatedness index's build, its notes read and the index not
        /// yet built (`Collection.relatednessIndex`).
        case relatednessBuild
    }

    private struct Key: Hashable {
        let kind: Kind
        let path: String
    }

    /// The holds armed and not yet taken, in the order armed.
    private static let armed = Mutex<[Key: [WorkHold]]>([:])

    private struct State {
        var reached = false
        var released = false
        var waiting: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    private init() {}

    /// Hold the next piece of `kind` work for `path`.
    static func arm(_ kind: Kind, for path: String) -> WorkHold {
        let hold = WorkHold()
        armed.withLock { $0[Key(kind: kind, path: path), default: []].append(hold) }
        return hold
    }

    /// The hold the next piece of `kind` work for `path` waits at, if one is
    /// armed — taken, so the piece after it is not held by it.
    static func take(_ kind: Kind, for path: String) -> WorkHold? {
        armed.withLock { holds -> WorkHold? in
            let key = Key(kind: kind, path: path)
            guard var waiting = holds[key], !waiting.isEmpty else { return nil }
            let hold = waiting.removeFirst()
            holds[key] = waiting.isEmpty ? nil : waiting
            return hold
        }
    }

    /// Whether the work has come to the hold.
    var isReached: Bool { state.withLock { $0.reached } }

    /// Where the held work waits until it is let go.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let goOn = state.withLock { state -> Bool in
                state.reached = true
                guard !state.released else { return true }
                state.waiting = continuation
                return false
            }
            if goOn { continuation.resume() }
        }
    }

    /// Let the work go on — now, or as it comes to the hold. A hold no work
    /// has taken is withdrawn, so nothing after the test is held by it.
    func release() {
        Self.armed.withLock { holds in
            for (key, waiting) in holds where waiting.contains(where: { $0 === self }) {
                let rest = waiting.filter { $0 !== self }
                holds[key] = rest.isEmpty ? nil : rest
            }
        }
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }
}

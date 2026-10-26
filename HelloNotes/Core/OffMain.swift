//
//  OffMain.swift
//  HelloNotes
//
//  Created by Chris Tham on 18/8/2026.
//

import Foundation

/// Run `body` away from the main actor, and let the compiler prove it did.
///
/// `Task.detached` looks like it guarantees this and does not. It governs
/// priority, task-locals and cancellation — never isolation. In this target,
/// which builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an
/// unannotated type is `@MainActor`, so a "detached" closure that touches one
/// hops straight back to the main actor. That is not a hypothetical: the walk's
/// `LocalTreeSource` was main-actor for exactly this reason, which turned every
/// directory listing on an iCloud vault into a synchronous XPC round-trip to
/// `fileproviderd` *on the main thread*, and froze the editor for five seconds
/// at a time. Two rounds of fixes reasoned correctly about which code was
/// "off the main actor" and changed nothing, because a build setting was
/// quietly deciding otherwise.
///
/// This helper closes that gap in two ways:
///
///  * `@concurrent` guarantees the hop to the concurrent executor, rather than
///    inheriting the caller's actor the way a plain `nonisolated async`
///    function does under approachable concurrency.
///  * **Computation, never a coordinated file call.** The body runs on a
///    thread of the pool, and a coordinated read or write — anything through
///    `FileIO` — holds that thread for as long as the file's provider holds
///    the file. Those go on the file's lane (`FileIO.onLane`), and a loop
///    over files awaits one in `offMainAwaiting` (implemented.md §51.62,
///    §51.63).
///  * `body` is a **nonisolated** `@Sendable` function type, so the compiler
///    flags a closure that touches main-actor state. **In this target that is a
///    warning, not an error**: the app builds in the Swift 5 language mode,
///    where isolation violations are warnings. And at runtime nothing hops:
///    `body` is synchronous, so it cannot await the main actor, and the
///    main-actor code it reaches simply runs on the pool thread, unchecked —
///    probed on 2026-09-29 with this target's flags (a main-actor computed
///    member read here ran with `pthread_main_np() == 0`). An earlier version
///    of this comment said the call hopped; it does not. So a warning inside an
///    `offMain` closure is a data race in waiting, not a stall; treat it as the
///    error it would be in Swift 6. (The test target reports the same code as
///    an error.)
///
/// Prefer this to `Task.detached` for any work that must not block the editor.
@concurrent
nonisolated func offMain<T: Sendable>(_ body: @Sendable () throws -> T) async rethrows -> T {
    try body()
}

/// `offMain` for work that awaits — a loop over notes whose reads and writes
/// go to their files' lanes (`FileIO.onLane`). The loop's own computation runs
/// off the main actor, as `offMain`'s does, and its file I/O on the lanes: a
/// file its provider holds then holds its lane, never a thread of the pool,
/// which `offMain`'s synchronous body holds for the whole wait (implemented.md
/// §51.63). `@concurrent` in the closure's type as well, so the body runs on
/// the global executor whatever context writes it — probed under this
/// target's settings before and after a lane hop, touching a main-actor type
/// and not. **Its body awaits nothing but a lane** (`FileIO.onLane`,
/// `onScanLane`): an `await` of main-actor state in it compiles without a
/// word in this target, Swift 5 or 6, and would hop to the main actor and
/// back on every pass.
@concurrent
nonisolated func offMainAwaiting<T: Sendable>(_ body: @concurrent @Sendable () async -> T) async -> T {
    await body()
}

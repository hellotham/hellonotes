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

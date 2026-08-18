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
///  * `body` is a **nonisolated** `@Sendable` function type, so a closure that
///    touches main-actor state is a *compile error* rather than a silent hop.
///    The rule stops depending on anyone remembering it.
///
/// Prefer this to `Task.detached` for any work that must not block the editor.
@concurrent
nonisolated func offMain<T: Sendable>(_ body: @Sendable () throws -> T) async rethrows -> T {
    try body()
}

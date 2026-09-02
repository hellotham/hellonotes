//
//  TypingGate.swift
//  HelloNotes
//
//  While the user is typing, **nothing else runs**. Not a save, not a scan, not
//  a word count, not a modal, not a check of any kind.
//
//  ## Why this is one object rather than a rule
//
//  "Don't do work on the typing path" was the rule for a long time and it was
//  enforced by everyone remembering it, in twelve different files, each with
//  its own debounce. That does not hold, and the reason is arithmetic: a
//  debounce fires when *its own* timer expires, so a 500ms sync debounce and a
//  600ms save debounce both fire in the middle of ordinary typing — a person
//  pausing to think crosses 500ms constantly. Every one of those files was
//  individually reasonable and the sum was an editor that stuttered.
//
//  So the gate is a single piece of state with a single question — *is the user
//  typing right now?* — and the work that used to schedule itself now asks
//  before it runs. Adding a new debounce somewhere is no longer a way to sneak
//  work onto the typing path; the gate is the only clock.
//
//  ## Deliberately not `@Observable`
//
//  An observable flag that flips on the first keystroke and back on idle would
//  invalidate every view reading it — which is the exact cost this exists to
//  remove. Consumers **ask** (`isTyping`) at the moment they are about to do
//  something; they never observe it. Idle is delivered by callback, once, to
//  the things that asked to be told.
//

import Foundation

@MainActor
final class TypingGate {

    static let shared = TypingGate()

    /// How long after the last keystroke counts as "still typing".
    ///
    /// Generous on purpose. The cost of waiting is that a save lands a moment
    /// later; the cost of being stingy is a save landing *between two
    /// keystrokes*, which on a File Provider volume can block the main thread
    /// for as long as the provider feels like taking. Those are not comparable,
    /// so this is sized for the slower typist rather than the faster disk.
    private static let idleAfter: Duration = .milliseconds(900)

    /// Is a keystroke burst in progress? Ask this before doing anything that is
    /// not the text view drawing a character.
    private(set) var isTyping = false

    private var idleTask: Task<Void, Never>?
    private var whenIdle: [String: () -> Void] = [:]

    private init() {}

    /// Called once per keystroke, and it must stay the cheapest thing on that
    /// path: two stores and a task swap, no allocation beyond the task itself.
    func keystroke() {
        isTyping = true
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleAfter)
            guard !Task.isCancelled else { return }
            self?.becameIdle()
        }
    }

    /// Run `work` when typing stops — or immediately, if it already has.
    ///
    /// Keyed so a repeated request replaces the previous one instead of
    /// stacking: forty keystrokes must not queue forty saves. The key is the
    /// caller's identity, not the work's.
    func onIdle(_ key: String, _ work: @escaping () -> Void) {
        guard isTyping else { work(); return }
        whenIdle[key] = work
    }

    /// Drop pending idle work for `key` without running it — for a caller that
    /// has been torn down, or whose work has been superseded by something more
    /// urgent (a flush on quit, say, which does the same job synchronously).
    func cancelIdleWork(_ key: String) {
        whenIdle.removeValue(forKey: key)
    }

    /// Typing has stopped: let everything that was waiting proceed.
    ///
    /// Also the path a flush takes — quitting, backgrounding, switching notes —
    /// because "the user stopped typing" and "the user left" want exactly the
    /// same catching-up done.
    func becameIdle() {
        idleTask?.cancel()
        idleTask = nil
        isTyping = false
        let pending = whenIdle
        whenIdle.removeAll()
        for work in pending.values { work() }
    }
}

//
//  DiagnosticSelfTest.swift
//  HelloNotes
//
//  Created by Chris Tham on 18/8/2026.
//
//  Drive the real app, against the real vault, without a person at the keyboard.
//
//  Every instrument that failed this session failed because it stood outside the
//  thing it measured: a synthetic vault with no UI, a probe on a starved thread,
//  a test harness that parks the main runloop. The only environment where the
//  reported bug reliably happens is *this app, with this user's 2,000-note
//  iCloud vault, with the real views observing* — and until now, exercising that
//  meant asking the user to type.
//
//  The first version of this file measured `noteDidSave` in isolation and found
//  it took 3–7 ms, which was true and useless: with no note selected the whole
//  downstream chain (`computeReferences`, the references panel, the inspector)
//  short-circuits at its first `guard`. Measuring one link of a chain says
//  nothing about the chain. So this version drives the *user's* path — select a
//  note, open the editor, type into it, let the debounce fire — and lets the
//  watchdog record what that costs.
//
//  Debug builds only, and inert unless `HN_SELFTEST` is set.
//

import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
enum DiagnosticSelfTest {

    /// What the self-test needs from the view it runs inside, so it can take the
    /// same path a person's click and keystrokes take rather than a private
    /// back door that proves nothing.
    struct Hooks {
        /// Set the window's selected note — the real selection binding.
        var select: (URL?) -> Void
        /// Resolve the editor the shell would open for a note.
        var editor: (Note) async -> EditorModel
    }

    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["HN_SELFTEST"] != nil
        #else
        return false
        #endif
    }

    /// Quit once the run finishes, so an unattended run leaves nothing behind.
    private static var shouldQuitAfter: Bool {
        ProcessInfo.processInfo.environment["HN_SELFTEST"] == "quit"
    }

    /// Exercise the reported-slow paths against `collection`.
    static func run(on collection: Collection, hooks: Hooks) async {
        guard isEnabled else { return }
        MainActorWatchdog.note("SELFTEST begin — \(collection.notes.count) notes in \(collection.rootURL.lastPathComponent)")

        await measureSelectingAndTyping(in: collection, hooks: hooks)
        await measureCreatingAndDeleting(in: collection)

        MainActorWatchdog.note("SELFTEST end")
        await quitIfAsked()
    }

    // MARK: - The path the user is actually on

    /// Select a note, open it, and type into it — the reported-slow sequence.
    ///
    /// Typing is simulated by appending to `EditorModel.text`, which is exactly
    /// what the text view's coordinator does on each keystroke: it runs the same
    /// `didSet`, the same 600 ms debounce, the same write, and the same
    /// `onSaved` → `noteDidSave` → `derivedRevision` → references chain.
    ///
    /// It types into a note it creates and then deletes, so the user's own notes
    /// are never written to.
    private static func measureSelectingAndTyping(in collection: Collection, hooks: Hooks) async {
        guard let scratch = await collection.createNote(title: scratchTitle) else {
            MainActorWatchdog.note("SELFTEST abort — could not create the scratch note")
            return
        }
        defer { Task { await cleanUp(scratch, in: collection, hooks: hooks) } }

        // 1 · Selecting it, which is the click the user reported as dead.
        let selectStarted = ContinuousClock.now
        hooks.select(scratch.fileURL)
        let editor = await hooks.editor(scratch)
        MainActorWatchdog.note("SELFTEST select+open: \(ContinuousClock.now - selectStarted)")

        // Let the shell settle so the typing measurement is not really a
        // measurement of opening.
        try? await Task.sleep(for: .milliseconds(1_500))

        // 2 · Typing. 40 keystrokes at 80 ms is about 3 seconds of ordinary
        //     typing and spans five debounce windows, so several autosaves land
        //     mid-stream — which is precisely when the freeze was reported.
        MainActorWatchdog.note("SELFTEST typing 40 keystrokes …")
        var worst: Duration = .zero
        var worstAt = 0
        for index in 0..<40 {
            let started = ContinuousClock.now
            editor.text.append(index % 12 == 11 ? "\n" : Character(UnicodeScalar(97 + index % 26)!))
            let elapsed = ContinuousClock.now - started
            if elapsed > worst { worst = elapsed; worstAt = index }
            try? await Task.sleep(for: .milliseconds(80))
        }
        MainActorWatchdog.note("SELFTEST worst single keystroke: \(worst) (at #\(worstAt))")

        // Let the final debounce and everything it triggers run to completion.
        try? await Task.sleep(for: .seconds(3))
    }

    /// Creating and deleting a note — both reported as forcing a reindex.
    private static func measureCreatingAndDeleting(in collection: Collection) async {
        let created = ContinuousClock.now
        guard let note = await collection.createNote(title: "\(scratchTitle) Churn") else { return }
        MainActorWatchdog.note("SELFTEST createNote: \(ContinuousClock.now - created)")

        let renamed = ContinuousClock.now
        let after = await collection.renameNote(note, to: "\(scratchTitle) Renamed")
        MainActorWatchdog.note("SELFTEST renameNote: \(ContinuousClock.now - renamed)")

        let deleted = ContinuousClock.now
        await collection.deleteNote(after ?? note)
        MainActorWatchdog.note("SELFTEST deleteNote: \(ContinuousClock.now - deleted)")
    }

    // MARK: - Leave nothing behind

    private static let scratchTitle = "HelloNotes Self-Test"

    private static func cleanUp(_ note: Note, in collection: Collection, hooks: Hooks) async {
        hooks.select(nil)
        await collection.deleteNote(note)
        MainActorWatchdog.note("SELFTEST cleaned up \(note.fileURL.lastPathComponent)")
    }

    /// Quit, but never from inside this task.
    ///
    /// `NSApplication.terminate:` spins a *nested* event loop while it waits for
    /// `applicationShouldTerminate`'s deferred reply, and that loop does not
    /// drain the main dispatch queue. Called from a main-actor async function it
    /// therefore deadlocks: the reply is produced by a main-actor `Task` that
    /// cannot start until this one returns, and this one cannot return until the
    /// reply arrives. The first run of this file wedged the app for four hours
    /// exactly that way. Hopping to the runloop first makes the quit an ordinary
    /// one, indistinguishable from ⌘Q.
    private static func quitIfAsked() async {
        guard shouldQuitAfter else { return }
        try? await Task.sleep(for: .seconds(2))
        MainActorWatchdog.note("SELFTEST quitting")
        #if os(macOS)
        // `RunLoop.perform`, *not* `DispatchQueue.main.async`.
        //
        // libdispatch refuses to re-enter a main queue that is already
        // draining, so a block queued from inside another main-queue block
        // cannot run under `terminate:`'s nested loop — which is the whole
        // deadlock, and hopping to the same queue does not escape it. A runloop
        // source is called out directly by the runloop rather than through the
        // queue, so the queue is idle when `terminate:` starts spinning and the
        // deferred reply can land.
        RunLoop.main.perform { NSApp.terminate(nil) }
        #endif
    }
}

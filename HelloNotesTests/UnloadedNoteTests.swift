//
//  UnloadedNoteTests.swift
//  HelloNotesTests
//
//  Clicking a note that has not downloaded yet.
//
//  Reported as "nothing happens — I have to click again once it materialises".
//  Two faults, and the second is worse than the one reported.
//
//  1. The tab was appended to `EditorTabs` only *after* `open` returned, and
//     `open` blocks in the file coordinator until a cloud file arrives. So the
//     click had no visible effect at all for the length of the download.
//
//  2. `open` read the file with `try? … ?? ""`. A failed read on a placeholder
//     became **an empty note**: `lastSavedText` was set to empty too, so the
//     first character typed made the buffer dirty against an empty baseline and
//     the next autosave wrote that over the original. `FileIO`'s own
//     documentation names this — "an editor that opens one will upload the
//     emptiness back over the original" — and the editor was the one place not
//     asking `hasContentAvailable`.
//
//  The second is why these tests are about *writing*, not about banners.
//
//  3. (24 September 2026.) The same loss by another door. The editor keeps its
//     own document, built from the model's text, and pushes it back when
//     editing settles — on the rule "if they differ, the editor's is newer". A
//     document built while the note was still loading holds nothing; if the
//     load lands without the document being refreshed, pushing it back is
//     saving an empty note. That is how "Start Here" became a new, empty file
//     written by HelloNotes itself, seven seconds after build 22 was launched
//     from TestFlight. `EditorModel.adopt` takes the editor's text only if it
//     was made from the load the model holds now.
//
//  4. (The same day, found by review.) And by a third: `open` let go of the
//     lock `willOpen` set before the content arrived, so for the whole of a
//     download — or of a read the provider was holding — whatever was typed
//     into the blank, or into the note the editor showed before, could be
//     saved over the note arriving. The buffer is write-locked for the whole
//     load now (`loadsInFlight`, docs/implemented.md §51.13).
//

import Testing
import Foundation
import Synchronization
@testable import HelloNotes

@Suite @MainActor
struct UnloadedNoteTests {

    private func makeNote(_ body: String) throws -> (Note, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-unloaded-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Real Note.md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        let note = Note(title: "Real Note", fileURL: url, lastModified: Date(),
                        fileSize: body.utf8.count)
        return (note, dir)
    }

    /// The buffer of a note that never loaded must never reach the disk.
    ///
    /// This is the data-loss path, asserted at the file rather than at the UI:
    /// the note on disk still says what it said.
    @Test func anUnloadedBufferIsNeverWrittenOverTheNote() async throws {
        let (note, dir) = try makeNote("# Real Note\n\nWork that took an hour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let editor = EditorModel()
        // The state the editor is in while the download is still running: it
        // knows which note it is, and it does not have the content.
        editor.willOpen(note)
        #expect(editor.loadFailure != nil, "an unloaded editor must say so")

        // Someone types into what looks like an empty document.
        editor.text = "x"
        await editor.save()

        let onDisk = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(onDisk.contains("Work that took an hour."),
                "the note was overwritten by a buffer that had never been loaded")
        #expect(editor.saveError != nil, "and the user has to be told the edit was not saved")
    }

    /// **An editor's copy made before the note loaded is never saved over it.**
    ///
    /// The shape of the Start Here loss: the editor's document is built while
    /// the note is loading (so from nothing), the load lands, and the document
    /// comes back — on a flush, at the end of editing, or as its host goes
    /// away. The model refuses it, because it was made from an earlier load,
    /// and the note on disk still says what it said. A copy made from the
    /// current load is an edit, and is taken and written as before.
    @Test func anEditorCopyFromBeforeTheLoadIsNeverSavedOverTheNote() async throws {
        let (note, dir) = try makeNote("# Start Here\n\nA five-minute tour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let editor = EditorModel()
        editor.willOpen(note)
        // What the editor built its document from: the load before this one.
        let documentLoad = editor.loadRevision
        await editor.open(note)
        #expect(editor.text.contains("A five-minute tour."))

        // The stale, empty document comes back — refused.
        #expect(editor.adopt("", fromLoad: documentLoad) == false)
        #expect(editor.text.contains("A five-minute tour."))
        await editor.flush()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8).contains("A five-minute tour."),
                "a document built before the load was saved over the note")

        // A document made from this load is the person's edit — taken, and saved.
        #expect(editor.adopt("# Start Here\n\nEdited.\n", fromLoad: editor.loadRevision))
        await editor.flush()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "# Start Here\n\nEdited.\n")
    }

    /// The negative control: the push the editor used to make — "if they
    /// differ, take the editor's" — does wipe the note. Without this, the test
    /// above could be passing for a reason that has nothing to do with the rule.
    @Test func takingAStaleCopyUnconditionallyWipesTheNote() async throws {
        let (note, dir) = try makeNote("# Start Here\n\nA five-minute tour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let editor = EditorModel()
        editor.willOpen(note)
        await editor.open(note)
        let staleDocumentText = ""
        if editor.text != staleDocumentText { editor.text = staleDocumentText }
        await editor.flush()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8).isEmpty,
                "the old push no longer reproduces the loss, so the test above proves nothing")
    }

    /// The edit is refused, not discarded.
    ///
    /// The buffer stays dirty on purpose — the same rule `saveBlockedReason`
    /// follows — so nothing the user typed is thrown away while the file is
    /// unavailable.
    @Test func theRefusedEditIsKept() async throws {
        let (note, dir) = try makeNote("original\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let editor = EditorModel()
        editor.willOpen(note)
        editor.text = "something the user typed"
        await editor.save()

        #expect(editor.text == "something the user typed", "the edit must survive the refusal")
        #expect(editor.isDirty, "and stay pending, so it can be written once the file is there")
    }

    /// Once the content is genuinely loaded, saving works normally — otherwise
    /// the guard above would be a very effective way of never saving anything.
    @Test func aLoadedNoteSavesNormally() async throws {
        let (note, dir) = try makeNote("original\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let editor = EditorModel()
        await editor.open(note)
        #expect(editor.loadFailure == nil, "a local file is available; nothing should be blocking")
        #expect(editor.text.contains("original"))

        editor.text = "edited\n"
        await editor.save()

        let onDisk = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(onDisk == "edited\n")
        #expect(editor.saveError == nil)
    }

    /// Opening clears a previous failure, so a note that failed once is not
    /// permanently unsavable.
    @Test func reopeningClearsTheFailure() async throws {
        let (note, dir) = try makeNote("original\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let editor = EditorModel()
        editor.willOpen(note)
        #expect(editor.loadFailure != nil)
        await editor.open(note)
        #expect(editor.loadFailure == nil, "the retry has to be able to succeed")
    }

    /// **Nothing typed while a note is loading is saved over it.**
    ///
    /// `open` let go of the lock `willOpen` set before the content arrived: it
    /// cleared `loadFailure`, then waited — for a cloud download, up to a
    /// minute; for the read, as long as the file's provider held it. The
    /// buffer in that wait is the blank a new tab starts with, and the load has
    /// not moved, so the editor's copy was taken with whatever was typed into
    /// it, and the next save — the end of an edit, the app going to the
    /// background — wrote it over the note that was arriving.
    ///
    /// The note is held here as a provider holds a file it is still
    /// materialising: under a coordinated write, which the read has to wait
    /// for — and so, before the fix, did the save, which then went second. The
    /// save is awaited: refused, it returns at once; queued behind the file, it
    /// returns when the provider lets go of its own accord, and has written.
    @Test func typingIntoANoteStillLoadingIsNeverSavedOverIt() async throws {
        let body = "# Start Here\n\nA five-minute tour.\n"
        let (note, dir) = try makeNote(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ProviderHold(note.fileURL)
        defer { provider.release() }

        let editor = EditorModel()
        editor.willOpen(note)
        let opening = Task { await editor.open(note) }
        // `open` has taken over from `willOpen`, and is waiting on the read.
        try await waitUntil { editor.loadFailure == nil }

        // Typed into the blank on screen, carried as the editor carries it, saved.
        #expect(editor.adopt("Typed while it loaded.\n", fromLoad: editor.loadRevision))
        await editor.save()

        provider.release()
        await opening.value
        let onDisk = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(onDisk == body, "what was typed while the note loaded was saved over the note")
        #expect(editor.text == body && !editor.isDirty, "the editor does not show the note that arrived")

        // The control: once the load has landed, a save writes.
        editor.text = body + "Typed after it loaded.\n"
        await editor.save()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == body + "Typed after it loaded.\n")
    }

    /// The same wait in an editor that was showing another note — a retry from
    /// the "couldn't be read" banner, or any model opened a second time. The
    /// buffer during the wait is then the *previous* note, and a flush (the app
    /// going to the background) wrote that note, typing and all, into the file
    /// of the one being opened.
    @Test func anEditorOpeningItsNextNoteNeverSavesTheLastOneOverIt() async throws {
        let firstBody = "# First\n\nThe note that was open.\n"
        let secondBody = "# Second\n\nThe note being opened.\n"
        let (first, firstDir) = try makeNote(firstBody)
        let (second, secondDir) = try makeNote(secondBody)
        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }
        let editor = EditorModel()
        await editor.open(first)
        let provider = ProviderHold(second.fileURL)
        defer { provider.release() }

        let opening = Task { await editor.open(second) }
        try await waitUntil { editor.note?.fileURL == second.fileURL }

        editor.text += "Typed while the second note loaded.\n"
        await editor.flush()

        provider.release()
        await opening.value
        let secondOnDisk = try String(contentsOf: second.fileURL, encoding: .utf8)
        #expect(secondOnDisk == secondBody, "the note that was open was saved over the one being opened")
        #expect(try String(contentsOf: first.fileURL, encoding: .utf8) == firstBody)
        #expect(editor.text == secondBody && !editor.isDirty)
    }
}

extension UnloadedNoteTests {
    /// Wait for the editor to get somewhere — polled, because every test in
    /// this target shares the main actor, and under a full run a step can take
    /// seconds to be scheduled. The cap only ends a test that is broken.
    func waitUntil(_ condition: () -> Bool,
                   sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "the editor never got there", sourceLocation: sourceLocation)
    }

    /// A change seen on disk while the note is still loading is the load's to
    /// read, not something to reconcile. Checked then, the file is compared
    /// with the baseline of whatever the buffer held before — nothing, in a
    /// new tab — and with anything typed in the wait, that is a conflict
    /// banner over a note that has only just arrived. A provider writing the
    /// file as it downloads is exactly what makes the watcher look.
    @Test func aChangeSeenWhileTheNoteLoadsIsNotAConflict() async throws {
        let body = "# Start Here\n\nA five-minute tour.\n"
        let (note, dir) = try makeNote(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ProviderHold(note.fileURL)
        defer { provider.release() }

        let editor = EditorModel()
        editor.willOpen(note)
        let opening = Task { await editor.open(note) }
        try await waitUntil { editor.loadFailure == nil }
        #expect(editor.adopt("Typed while it loaded.\n", fromLoad: editor.loadRevision))

        await editor.reconcileWithDisk()

        provider.release()
        await opening.value
        #expect(!editor.hasConflict, "a conflict was raised over the note that had just arrived")
        #expect(editor.text == body)
    }
}

// MARK: - Where opening asks about the download

extension UnloadedNoteTests {
    /// **Opening a note asks the file provider off the main actor.**
    /// `willOpen` and `open` asked whether the note had downloaded on the main
    /// actor, before the load's read off it — the question `reconcileWithDisk`
    /// stopped asking there (implemented.md §51.15, §51.36). On a File
    /// Provider's file it is a round trip to the provider.
    @Test func openingAsksAboutTheDownloadOffTheMainActor() async throws {
        let (note, dir) = try makeNote("# Real Note\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let looks = Locked<[Bool]>([])
        FileIO.materialisedProbes.withLock { $0[note.fileURL.path] = { onMain in looks.mutate { $0.append(onMain) } } }
        defer { _ = FileIO.materialisedProbes.withLock { $0.removeValue(forKey: note.fileURL.path) } }

        let editor = EditorModel()
        editor.willOpen(note)
        await editor.open(note)

        #expect(editor.text == "# Real Note\n")
        #expect(!looks.value.isEmpty, "nothing asked, so this tests nothing")
        #expect(!looks.value.contains(true), "opening asked the file provider on the main thread: \(looks.value)")
    }
}

// MARK: - A note that arrives after its load failed

extension UnloadedNoteTests {
    /// An editor whose note failed to load because it was a stand-in — what a
    /// download that ran out of time leaves, an iCloud item not yet here or a
    /// cloud mirror's placeholder — and a switch for when it arrives.
    private func failedToLoad(_ body: String) async throws -> (EditorModel, Note, URL, Locked<Bool>) {
        let (note, dir) = try makeNote(body)
        let notHereYet = Locked(true)
        let editor = EditorModel()
        editor.isPlaceholder = { _ in notHereYet.value }
        await editor.open(note)
        #expect(editor.loadFailure != nil && editor.text.isEmpty, "the load did not fail, so this tests nothing")
        return (editor, note, dir, notHereYet)
    }

    /// **A note that arrives after its load failed is open.** A reconcile —
    /// the change seen on disk as the download lands — took the file's text
    /// and left the failure: the note on screen under a banner saying it is
    /// not open, and every save of it refused.
    @Test func aNoteThatArrivesAfterItsLoadFailedIsOpen() async throws {
        let body = "# Real Note\n\nIt arrived late.\n"
        let (editor, note, dir, notHereYet) = try await failedToLoad(body)
        defer { try? FileManager.default.removeItem(at: dir) }

        notHereYet.set(false)
        await editor.reconcileWithDisk()
        #expect(editor.text == body)
        #expect(editor.loadFailure == nil, "the note arrived and the editor still says it is not open")

        editor.text = body + "Typed once it arrived.\n"
        await editor.save()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == body + "Typed once it arrived.\n",
                "a note that arrived after its load failed could not be saved")
        #expect(editor.saveError == nil)
    }

    /// What was typed into the blank before the note arrived is the person's,
    /// and the note that arrived is theirs: a conflict, as any change met
    /// with unsaved typing is — and one that can be resolved either way. Keep
    /// Mine was refused by the failure the arrival had not cleared.
    @Test func typingIntoTheBlankIsAConflictWithTheNoteThatArrives() async throws {
        let body = "# Real Note\n\nIt arrived late.\n"
        let (editor, note, dir, notHereYet) = try await failedToLoad(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        editor.text = "Typed into the blank.\n"
        await editor.save()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == body)

        notHereYet.set(false)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict && editor.text == "Typed into the blank.\n")
        #expect(editor.loadFailure == nil)

        await editor.resolveConflictKeepingMine()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "Typed into the blank.\n",
                "Keep Mine was refused: the note that arrived was still marked as not loaded")
    }

    /// **Try Again never opens the note over what a refused save kept.** The
    /// banner's Try Again flushes, which a note not loaded refuses, and then
    /// loaded the note over the buffer: what was typed into the blank went —
    /// and with nothing on disk to load, the blank of a second failure went
    /// over it too. Now a failure keeps it, and the note, once here, is set
    /// against it as a conflict.
    @Test func tryAgainKeepsWhatWasTypedIntoTheBlank() async throws {
        let body = "# Real Note\n\nIt arrived late.\n"
        let (editor, note, dir, notHereYet) = try await failedToLoad(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        editor.text = "Typed into the blank.\n"

        await editor.open(note)   // Try Again, before the note is here
        #expect(editor.loadFailure != nil)
        #expect(editor.text == "Typed into the blank.\n", "a second failure loaded the blank over the typing")

        notHereYet.set(false)
        await editor.open(note)   // and again, once it is
        #expect(editor.loadFailure == nil, "Try Again did not open the note")
        #expect(editor.text == "Typed into the blank.\n", "Try Again loaded the note over the typing")
        #expect(editor.hasConflict, "the note that arrived was not set against the typing")
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == body)

        await editor.resolveConflictReloading()
        #expect(editor.text == body && !editor.isDirty)
    }

    /// Typed or not, Try Again opens a note that has arrived; with nothing
    /// typed there is nothing to set against it.
    @Test func tryAgainWithNothingTypedOpensTheNote() async throws {
        let body = "# Real Note\n\nIt arrived late.\n"
        let (editor, note, dir, notHereYet) = try await failedToLoad(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        notHereYet.set(false)
        await editor.open(note)
        #expect(editor.loadFailure == nil && !editor.hasConflict && editor.text == body && !editor.isDirty)
    }

    /// Another note is not opened over what a refused save kept.
    @Test func anotherNoteIsNotOpenedOverARefusedSave() async throws {
        let (editor, note, dir, _) = try await failedToLoad("# Real Note\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (other, otherDir) = try makeNote("# Other\n")
        defer { try? FileManager.default.removeItem(at: otherDir) }
        editor.text = "Typed into the blank.\n"

        await editor.open(other)
        #expect(editor.note?.fileURL == note.fileURL && editor.text == "Typed into the blank.\n",
                "another note was opened over typing that had not been saved")
    }
}

/// A file held the way a cloud provider holds one it is still writing: under a
/// coordinated write, which a coordinated read — `FileIO.readData` — waits for,
/// and so does a coordinated write. Released once, by whichever of a test's
/// paths gets there first — or by itself after `limit`, so that a save queued
/// behind it (the defect) finishes, writes, and fails the test rather than
/// hanging it.
nonisolated private final class ProviderHold: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    init(_ url: URL, limit: DispatchTimeInterval = .seconds(10)) {
        let held = DispatchSemaphore(value: 0)
        Thread { [done] in
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                             error: &error) { _ in
                held.signal()
                _ = done.wait(timeout: .now() + limit)
            }
            if error != nil { held.signal() }
        }.start()
        held.wait()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        done.signal()
    }
}

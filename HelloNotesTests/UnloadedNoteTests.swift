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

import Testing
import Foundation
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
}

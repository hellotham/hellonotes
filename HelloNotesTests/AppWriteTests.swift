//
//  AppWriteTests.swift
//  HelloNotesTests
//
//  A change the app makes to an open note — a tag, a link or a summary
//  accepted, the link review, a rewrite in place of the body or below it, a
//  version restored from History, a template — is written when it is made
//  (`EditorModel.applyEdit`, implemented.md §51.36).
//

import Foundation
import Testing
@testable import HelloNotes

@Suite @MainActor
struct AppWriteTests {
    static let note = "---\ntitle: Log\n---\n# Log\n\nAs it was.\n"

    /// Each door, with the change its caller hands `applyEdit`.
    enum Write: String, CaseIterable, CustomTestStringConvertible {
        case tag, link, summary, rewrite, insertBelow, restore, template

        var testDescription: String { rawValue }

        func applied(to text: String) -> String {
            switch self {
            case .tag:         NoteEdits.addingTag("filed", to: text)
            case .link:        NoteEdits.addingRelatedLink("Other Note", to: text)
            case .summary:     NoteEdits.settingSummary("A log of things.", in: text)
            case .rewrite:     String(text.dropLast(FrontMatter.body(of: text).count)) + "# Log\n\nRewritten.\n"
            case .insertBelow: text.trimmingTrailingNewlines() + "\n\nRewritten.\n"
            case .restore:     "# Log\n\nAn older version.\n"
            case .template:    text + "\n## From a template\n"
            }
        }
    }

    private func editorOnANote() async throws -> (EditorModel, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-app-write-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Log.md")
        try Data(Self.note.utf8).write(to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Log", fileURL: url, lastModified: Date(), fileSize: Self.note.utf8.count))
        return (editor, url, dir)
    }

    /// What the file says once `holds` is true of it, or after ten seconds: a
    /// save is a task away from whatever starts it, and the rest of the suite
    /// can hold the main actor for seconds at a time.
    private func file(at url: URL, until holds: (String) -> Bool) async -> String {
        let deadline = ContinuousClock.now + .seconds(10)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        while !holds(text), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return text
    }

    /// **Written when it is made.** A text change schedules no save, so each
    /// of these changed the buffer and nothing else, and reached the file at
    /// the next flush — a switch of note, mode or app, a tab closing,
    /// quitting — and a crash before one lost it: the shape §51.30 fixed for
    /// the Properties panel alone.
    @Test(arguments: Write.allCases)
    func anAppWriteIsWrittenWithoutAFlush(_ write: Write) async throws {
        let (editor, url, dir) = try await editorOnANote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = write.applied(to: Self.note)
        #expect(expected != Self.note, "the change changes nothing, so this tests nothing")

        #expect(editor.applyEdit { write.applied(to: $0) })
        let file = await file(at: url, until: { $0 == expected })
        #expect(file == expected, "the app's change was not written; the file says \(file.debugDescription)")
        // The bytes land before the model hears that they have: a save joins
        // the write in flight, and returns once it has.
        await editor.save()
        #expect(!editor.isDirty)
    }

    /// No change is no write.
    @Test func noChangeWritesNothing() async throws {
        let (editor, url, dir) = try await editorOnANote()
        defer { try? FileManager.default.removeItem(at: dir) }
        editor.typed(Self.note + "Typed, and not yet written.\n")
        let writes = editor.savedRevision

        #expect(!editor.applyEdit { _ in nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(editor.savedRevision == writes, "a change that changed nothing wrote the note")
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.note)
    }

    /// The model's own save, so its rules stand: with a conflict open the
    /// note is not written — Keep Mine is the one way mine reaches it.
    @Test func aConflictStillHoldsAnAppWrite() async throws {
        let (editor, url, dir) = try await editorOnANote()
        defer { try? FileManager.default.removeItem(at: dir) }
        editor.typed(Self.note + "Mine.\n")
        let theirs = Self.note + "Theirs.\n"
        try Data(theirs.utf8).write(to: url)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict)

        editor.applyEdit { Write.tag.applied(to: $0) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try String(contentsOf: url, encoding: .utf8) == theirs, "an app write went over a conflict")
        #expect(editor.hasConflict && editor.isDirty)
    }
}

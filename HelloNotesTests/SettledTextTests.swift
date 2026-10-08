//
//  SettledTextTests.swift
//  HelloNotesTests
//
//  What follows the note without editing it — Preview, the inspector, another
//  scene's mirror — follows `EditorModel.settledText`: the text as of the last
//  pause in typing. The Markdown pane writes the buffer on every keystroke, and
//  everything that followed the buffer followed it there, on the main actor
//  (docs/implemented.md §51.18). Typing settles once it pauses; anything else
//  settles at once.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct SettledTextTests {

    /// Whether `condition` comes to hold within `timeout`, awaiting between
    /// looks — the settle is a main-actor task, and only an `await` lets one run.
    private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func aKeystrokeSettlesOnceTypingPauses() async {
        let editor = EditorModel()
        let before = editor.settledText.version
        editor.typed("a")
        #expect(editor.settledText.version == before, "a keystroke settled at once")
        #expect(await eventually { editor.settledText.version == editor.textVersion },
                "typing never settled")
        #expect(editor.settledText.text == "a")
    }

    /// A pause is a pause in *typing*: keys closer together than the delay keep
    /// putting it off.
    @Test func typingThatGoesOnDoesNotSettle() async {
        let editor = EditorModel()
        let before = editor.settledText.version
        for count in 1...5 {
            editor.typed(String(repeating: "a", count: count))
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(editor.settledText.version == before, "it settled while typing went on")
        #expect(await eventually { editor.settledText.text == "aaaaa" }, "typing never settled")
    }

    /// Everything that is not a keystroke — an app write, the live editor's
    /// text carried in, a load — is not typing, and settles at once, taking
    /// any typing not yet settled with it.
    @Test func anythingButTypingSettlesAtOnce() {
        let editor = EditorModel()
        editor.text = "written"
        #expect(editor.settledText.version == editor.textVersion)
        editor.typed("typed")
        editor.applyEdit { $0 + "!" }
        #expect(editor.settledText.version == editor.textVersion)
        #expect(editor.settledText.text == "typed!")
    }

    /// Editing stopping is a pause: a flush — the end of editing, a switch of
    /// mode or note, going to the background — settles what was typed.
    @Test func aFlushSettles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettledText-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Note.md")
        try Data("On disk.".utf8).write(to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Note", fileURL: url, lastModified: Date(), fileSize: 8))
        #expect(editor.settledText.text == "On disk.", "a load did not settle at once")

        editor.typed("Typed.")
        #expect(editor.settledText.text == "On disk.")
        await editor.flush(lettingGo: false)
        #expect(editor.settledText.version == editor.textVersion, "a flush did not settle what was typed")
        #expect(editor.settledText.text == "Typed.")
    }
}

//
//  PropertiesPanelTests.swift
//  HelloNotesTests
//
//  The Properties panel reads a note's front matter on every change to the
//  note while it shows, and writes it back when a change is committed. Reading
//  it has to cost the front matter, not the note, writing it back has to leave
//  the body exactly as it was, and a commit has to reach the file when it is
//  made (implemented.md §51.30).
//

import Testing
import MarkdownCore
import Foundation
import MarkdownEditor
@testable import HelloNotes

@Suite @MainActor
struct PropertiesPanelTests {

    private static let frontMatter = "---\ntitle: Log\npriority: 2\n---\n"

    /// Reading the properties reads the front matter and stops. It split the
    /// whole note into lines and counted its characters to find where the body
    /// began — on the main actor, whenever the panel redrew: 83ms a megabyte
    /// for the bridged text an editor hands back.
    @Test func readingPropertiesReadsOnlyTheFrontMatter() {
        let short = MainThreadReads(text: Self.frontMatter + "Body.\n")
        let long = MainThreadReads(
            text: Self.frontMatter + String(repeating: "A line of the body, and another.\n", count: 5_000)
        )
        #expect(FrontMatter.properties(in: short as String).map(\.key) == ["title", "priority"])
        #expect(FrontMatter.properties(in: long as String).map(\.key) == ["title", "priority"])
        #expect(short.onMain > 0, "the probe saw nothing, so its count says nothing")
        #expect(long.onMain <= short.onMain + 2,
                "reading the properties read the whole note: \(long.onMain) reads against \(short.onMain)")
    }

    /// A front-matter line ending in CRLF is one character shorter than a count
    /// of its pieces says — `\r\n` is a single `Character` — and the body's
    /// start was found by counting. So a property written back cut a letter off
    /// the front of the body for each such line.
    @Test func writingAPropertyKeepsTheBodyWhateverTheLineEndings() throws {
        let text = "---\ntitle: Log\r\npriority: 2\n---\nBody starts here.\n"
        var properties = FrontMatter.properties(in: text)
        let priority = try #require(properties.firstIndex { $0.key == "priority" })
        properties[priority].text = "3"

        let written = FrontMatter.applying(properties, to: text)
        #expect(written.hasSuffix("---\nBody starts here.\n"), "the body lost its start: \(written.debugDescription)")
        #expect(FrontMatter.body(of: text) == "Body starts here.\n")
    }

    // MARK: - The draft

    /// The panel's rows are a draft (`PropertyDraft`): typing changes them, and
    /// a commit writes them. Bound straight to the note, each character typed
    /// in a field rewrote the front matter and, in Edit, replaced the whole
    /// note on screen and cleared its undo. New API, so these could not fail
    /// first; the last is their control.

    private static let taken = FrontMatter.properties(in: frontMatter)

    private func version(_ editor: String, _ generation: Int) -> EditorModel.TextVersion {
        EditorModel.TextVersion(editor: editor, generation: generation)
    }

    /// What is being typed stays when the body moves — the carry as the field
    /// takes focus, a change made below the front matter.
    @Test func aDraftSurvivesTheBodyMoving() throws {
        var draft = PropertyDraft()
        _ = draft.follow(version("A", 1), properties: Self.taken)
        let priority = try #require(draft.rows.firstIndex { $0.key == "priority" })
        draft.rows[priority].text = "25"

        #expect(draft.follow(version("A", 2), properties: Self.taken) == nil)
        #expect(draft.rows[priority].text == "25", "what was being typed was replaced when the body moved")
    }

    /// A tab switch with an edit not yet written hands it back for the note it
    /// was made in — neither lost nor written into the note switched to.
    @Test func anEditLeftByATabSwitchGoesToItsOwnNote() throws {
        var draft = PropertyDraft()
        _ = draft.follow(version("A", 1), properties: Self.taken)
        let priority = try #require(draft.rows.firstIndex { $0.key == "priority" })
        draft.rows[priority].text = "25"

        let other = FrontMatter.properties(in: "---\ntitle: Other\n---\n")
        let pending = draft.follow(version("B", 7), properties: other)
        #expect(pending?.note == version("A", 1), "the edit was not handed back for its own note")
        #expect(pending?.rows[priority].text == "25")
        #expect(draft.rows == other, "the rows did not move to the note switched to")
    }

    /// The control: a change to the front matter under the rows — a reload, a
    /// tag accepted, a commit landing — is what they show.
    @Test func aChangeToTheFrontMatterIsWhatTheRowsShow() throws {
        var draft = PropertyDraft()
        _ = draft.follow(version("A", 1), properties: Self.taken)
        let priority = try #require(draft.rows.firstIndex { $0.key == "priority" })
        draft.rows[priority].text = "25"

        let reloaded = FrontMatter.properties(in: "---\ntitle: Log\npriority: 7\n---\n")
        #expect(draft.follow(version("A", 2), properties: reloaded) == nil)
        #expect(draft.rows == reloaded)
        #expect(!draft.isEdited)
    }

    // MARK: - A commit is written

    private static let note = "---\ntitle: Log\npriority: 2\n---\n\n# Log\n\nAs it was.\n"

    /// The panel's three commits, each as the rows it hands the note.
    enum Commit: String, CaseIterable {
        /// Add, with a value typed and the field left.
        case added
        /// A value typed over, and Return.
        case edited
        /// A row's remove button.
        case removed

        func rows(from text: String) -> [Property] {
            var rows = FrontMatter.properties(in: text)
            switch self {
            case .added:
                rows.append(Property(key: "status", kind: .text, text: "draft", bool: false, items: []))
            case .edited:
                if let index = rows.firstIndex(where: { $0.key == "priority" }) { rows[index].text = "3" }
            case .removed:
                rows.removeAll { $0.key == "priority" }
            }
            return rows
        }

        /// Whether `text` holds this commit.
        func isIn(_ text: String) -> Bool {
            switch self {
            case .added:   text.contains("status: draft")
            case .edited:  text.contains("priority: 3")
            case .removed: !text.contains("priority:")
            }
        }
    }

    /// An editor on a note with front matter, as a tab holds one.
    private func editorOnANote() async throws -> (EditorModel, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-commit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Log.md")
        try Data(Self.note.utf8).write(to: url)
        let editor = EditorModel()
        await editor.open(Note(title: "Log", fileURL: url, lastModified: Date(), fileSize: Self.note.utf8.count))
        return (editor, url, dir)
    }

    /// What the file says once `holds` is true of it, or after ten seconds, as
    /// the suite's other waits for a write allow: a save is a task away from
    /// whatever starts it, and the rest of the suite can hold the main actor
    /// for seconds at a time — two seconds ran out under it, in the full run,
    /// before the save had had its turn.
    private func file(at url: URL, until holds: (String) -> Bool) async -> String {
        let deadline = ContinuousClock.now + .seconds(10)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        while !holds(text), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return text
    }

    /// A commit — Return, leaving a field, a toggle, Add, a row's remove
    /// button — is written when it is made, from the inspector and from the
    /// note's popover alike: both hand their rows to `setProperties`. A text
    /// change schedules no save, so it reached the file only at the next
    /// flush — a switch of note, mode or app, a tab closing, quitting — and a
    /// crash before one lost it. On the iPad simulator `status`, added to
    /// Intelligence.md, was not on disk five seconds later.
    @Test(arguments: Commit.allCases)
    func aCommitIsWrittenWithoutAFlush(_ commit: Commit) async throws {
        let (editor, url, dir) = try await editorOnANote()
        defer { try? FileManager.default.removeItem(at: dir) }

        editor.setProperties(commit.rows(from: editor.text))
        #expect(commit.isIn(editor.text), "the commit never reached the note")
        let file = await file(at: url, until: commit.isIn)
        #expect(commit.isIn(file), "the commit was not written; the file says \(file.debugDescription)")
        #expect(file == editor.text, "what was written is not the note")
    }

    /// The control: the same commit and a flush is on the disk — the file is
    /// read as it is written, and the commit is in the note, so what is
    /// missing without the flush is the write.
    @Test func aFlushWritesACommit() async throws {
        let (editor, url, dir) = try await editorOnANote()
        defer { try? FileManager.default.removeItem(at: dir) }

        editor.setProperties(Commit.added.rows(from: editor.text))
        await editor.flush()
        #expect(Commit.added.isIn(try String(contentsOf: url, encoding: .utf8)))
    }

    /// In Edit a commit is made to what is on screen — `applyEdit` carries the
    /// typing first — so what is written is the typing and the property
    /// together: the model's own save, of the whole note, with the editor
    /// wired as `EditorHost` wires it.
    @Test func aCommitWritesTheTypingOnScreenWithIt() async throws {
        let (editor, url, dir) = try await editorOnANote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let document = EditorDocument(text: editor.text)
        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)
        editor.willFlush = { [weak editor] in
            guard let editor else { return }
            load.carry(document, into: editor)
        }

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        editor.setProperties(Commit.added.rows(from: editor.text))
        let file = await file(at: url, until: Commit.added.isIn)
        #expect(Commit.added.isIn(file), "the commit was not written")
        #expect(file.contains("As it was. Typed."), "the typing on screen was not written with it")
    }

    /// §51.15's rule stands: rows handed back as the note has them — a field
    /// gaining focus hands its value back — are no change, and no change is
    /// no write. The note holds typing not yet written, so a commit that saved
    /// whatever it was handed would write that; it waits for its own end of
    /// editing.
    @Test func anUnchangedCommitWritesNothing() async throws {
        let (editor, url, dir) = try await editorOnANote()
        defer { try? FileManager.default.removeItem(at: dir) }
        editor.typed(editor.text.replacingOccurrences(of: "As it was.", with: "As it was. Typed."))
        let generation = editor.textGeneration
        let writes = editor.savedRevision

        editor.setProperties(FrontMatter.properties(in: editor.text))
        #expect(editor.textGeneration == generation, "an unchanged commit moved the note")
        try await Task.sleep(for: .milliseconds(300))
        #expect(editor.savedRevision == writes, "an unchanged commit wrote the note")
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.note)
    }
}

/// The properties are read from the block the editor folds, and no further:
/// `FrontMatter` looked for the closing fence to the end of the note, so a
/// note opening with a rule it never closed was read whole at each pause in
/// typing, and a block closed past the editor's limit was front matter here
/// and text in the editor (implemented.md §51.36).
struct FrontMatterLimitTests {
    private func folds(_ text: String) -> Bool {
        let parse = BlockParser.fullParse(text as NSString)
        return parse.blocks.first?.kind == .frontMatter
    }

    @Test func theBlockIsTheOneTheEditorFolds() {
        let filler = (0..<300).map { "key\($0): value" }
        for closing in [3, BlockParser.frontMatterSearchLimit - 1, BlockParser.frontMatterSearchLimit, 250] {
            let text = "---\n" + filler.prefix(closing - 1).joined(separator: "\n") + "\n---\nBody.\n"
            #expect(!FrontMatter.properties(in: text).isEmpty == folds(text),
                    "closed at line \(closing): Properties and the editor disagree")
        }
    }

    @Test func aRuleNeverClosedIsNoFrontMatter() {
        let text = "---\nkey: value\n" + String(repeating: "A line of the note.\n", count: 50_000)
        #expect(FrontMatter.properties(in: text).isEmpty)
        #expect(!folds(text))
    }
}

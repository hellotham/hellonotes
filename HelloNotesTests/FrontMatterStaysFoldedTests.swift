//
//  FrontMatterStaysFoldedTests.swift
//  HelloNotesTests
//
//  A note's front matter is folded in Edit until a caret goes into it
//  (`EditorDocument.frontMatterRange`). Opened straight into Edit it came up
//  unfolded — `---`, `title:`, `tags:` in monospace between the title and the
//  first heading — where the same note switched to Edit from Preview did not
//  (seen on the HN-iPad simulator, 25 September). The host keeps the caret
//  across a replacement of the document's text, and it put back one nobody had
//  placed: a document's `selectedRange` reads `{0, 0}` before anything puts a
//  caret in it, and put back, that is a caret *arriving* at offset 0 — in the
//  front matter.
//
//  Each document here is built as `EditorHost` builds one and settled with its
//  buffer as the host settles it (`DocumentLoad.settleWithBuffer`), and the
//  caret the replacement names is put back as the host's proxy puts it back —
//  through the document's `selectionDidChange`, which is what folds and
//  unfolds.
//

import Testing
import Foundation
import MarkdownEditor
@testable import HelloNotes

@Suite @MainActor
struct FrontMatterStaysFoldedTests {

    /// DefaultCollection's Linking.md, as far as its first paragraph.
    private static let linking = "---\ntitle: Linking\ntags: [tour]\naliases: [Links, Wiki Links]\n---\n\n"
        + "# Linking\n\nType [[ and HelloNotes offers every note in the collection.\n"

    private func makeNote(_ text: String = Self.linking) throws -> (Note, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-fold-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Linking.md")
        try Data(text.utf8).write(to: url)
        return (Note(title: "Linking", fileURL: url, lastModified: Date(), fileSize: text.utf8.count), dir)
    }

    /// A new tab's document: the tab is on screen before `open` has loaded
    /// its note (`EditorWiring.open`), so the host builds the document from
    /// the buffer as it stands — nothing of the note.
    private func newTab(on note: Note) -> (EditorModel, EditorDocument, DocumentLoad) {
        let editor = EditorModel()
        editor.willOpen(note)
        let generation = editor.textGeneration
        let document = EditorDocument(text: editor.text)
        return (editor, document, DocumentLoad(built: document, at: generation, for: editor))
    }

    /// A document built from the loaded note: the load landed first, or the
    /// note came to Edit from Preview.
    private func loaded(_ note: Note) async -> (EditorModel, EditorDocument, DocumentLoad) {
        let editor = EditorModel()
        await editor.open(note)
        let generation = editor.textGeneration
        let document = EditorDocument(text: editor.text)
        return (editor, document, DocumentLoad(built: document, at: generation, for: editor))
    }

    /// Settle `document` with its buffer the way the host does, and put back
    /// the caret the replacement names — what `EditorProxy.setSelection` does
    /// to the document.
    private func settle(_ document: EditorDocument, _ editor: EditorModel,
                        _ load: DocumentLoad) -> DocumentLoad.Replacement? {
        let replaced = load.settleWithBuffer(document, editor)
        if let caret = replaced?.caret { document.selectionDidChange(caret) }
        return replaced
    }

    private func offset(of needle: String, in document: EditorDocument) -> Int {
        (document.text as NSString).range(of: needle).location
    }

    // MARK: - Nobody has clicked into the note

    /// The report: a note opened straight into Edit. Its document is built
    /// while the note is still loading and holds nothing of it, so there is
    /// no caret to keep — and none may be made up. Put back as `{0, 0}` it
    /// unfolded the front matter; moved with the body, it opened the blank
    /// line under the front matter instead, a line's gap above the first
    /// heading that the same note from Preview does not have.
    @Test func aNoteOpenedStraightIntoEditOpensAsItDoesFromPreview() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = newTab(on: note)

        await editor.open(note)
        let replaced = try #require(settle(document, editor, load), "the note never reached the document")
        #expect(replaced.caret == nil,
                "a caret was put at \(String(describing: replaced.caret)) in a note nobody had clicked into")
        #expect(document.isFrontMatterFolded, "the note opened with its front matter unfolded")
        #expect(document.caret == nil)
    }

    /// A tag accepted — or a property changed in the panel — on a note nobody
    /// has clicked into. The write lands in the front matter and replaces the
    /// document; there was no caret to keep, and the `{0, 0}` put back opened
    /// the front matter under the panel.
    @Test func anAppWriteLeavesAnUntouchedNoteFolded() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await loaded(note)
        #expect(document.isFrontMatterFolded)

        editor.applyEdit { NoteEdits.addingTag("linking", to: $0) }
        let replaced = try #require(settle(document, editor, load), "the tag never reached the document")
        #expect(document.text.contains("linking"))
        #expect(replaced.caret == nil)
        #expect(document.isFrontMatterFolded,
                "accepting a tag unfolded the front matter of a note nobody had clicked into")
    }

    /// The note changed elsewhere — another app, another device — while open
    /// and untouched: a reload, and the same made-up caret.
    @Test func aReloadLeavesAnUntouchedNoteFolded() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await loaded(note)

        try Data((Self.linking + "\nAdded on another device.\n").utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        let replaced = try #require(settle(document, editor, load), "the change elsewhere never reached the document")
        #expect(document.text.contains("Added on another device."))
        #expect(replaced.caret == nil)
        #expect(document.isFrontMatterFolded, "a reload unfolded the front matter of a note nobody had clicked into")
    }

    // MARK: - A caret someone put there (the controls)

    /// The negative control, and the reason the caret is kept at all: an app
    /// write lands in the front matter, above a caret in the body, and the
    /// caret keeps its place in the body — so what is typed next goes where
    /// the person was typing. Passed before the change, and passes now.
    @Test func anAppWriteKeepsACaretInTheBody() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await loaded(note)
        let typing = NSRange(location: offset(of: "HelloNotes offers", in: document), length: 0)
        document.selectionDidChange(typing)

        editor.applyEdit { NoteEdits.addingTag("linking", to: $0) }
        let replaced = try #require(settle(document, editor, load))
        let caret = try #require(replaced.caret, "the caret in the body was not put back")
        #expect(caret.location == offset(of: "HelloNotes offers", in: document),
                "the caret moved \(caret.location - offset(of: "HelloNotes offers", in: document)) characters within the body")
        #expect(document.caret == caret)
        #expect(document.isFrontMatterFolded)
    }

    /// A caret the person put in the front matter — editing its YAML — stays
    /// there across a write, and the front matter stays open around it.
    @Test func aCaretInTheFrontMatterKeepsItOpen() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await loaded(note)
        let inYAML = NSRange(location: offset(of: "aliases:", in: document), length: 0)
        document.selectionDidChange(inYAML)
        #expect(!document.isFrontMatterFolded, "a caret in the front matter did not open it, so this tests nothing")

        editor.applyEdit { NoteEdits.addingTag("linking", to: $0) }
        let replaced = try #require(settle(document, editor, load))
        #expect(replaced.caret == inYAML)
        #expect(!document.isFrontMatterFolded, "the front matter being edited folded under the caret")
    }

    /// Tapped into the new tab while its note was still loading: that caret is
    /// the person's, at 0 of nothing, and it goes where the body now begins —
    /// not into the front matter that arrived above it.
    @Test func aCaretPutInWhileTheNoteLoadedGoesToTheBody() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = newTab(on: note)
        document.selectionDidChange(NSRange(location: 0, length: 0))

        await editor.open(note)
        let replaced = try #require(settle(document, editor, load))
        #expect(replaced.caret?.location == FrontMatter.bodyOffset(in: document.text))
        #expect(document.isFrontMatterFolded)
    }
}

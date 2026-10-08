//
//  WhoseTextWinsTests.swift
//  HelloNotesTests
//
//  In Edit the live `EditorDocument` keeps its own copy of the note and the
//  `EditorModel`'s buffer is what is saved. When the two no longer hold the
//  same text, one of them has moved since they last matched, and that decides
//  which way they settle (`DocumentLoad`): the document moved — typing — so it
//  is carried into the buffer; the buffer moved — a write the app made, a load
//  — so it replaces the document. Every test here was a way the wrong one won.
//
//  The editors are wired as `EditorHost` wires them: `willFlush` carries the
//  document, and the host's hooks are the `DocumentLoad` calls it makes.
//

import Testing
import Foundation
import MarkdownEditor
@testable import HelloNotes

@Suite @MainActor
struct WhoseTextWinsTests {

    private static let body = "# Log\n\nAs it was.\n"

    private func makeNote(_ body: String = Self.body, named name: String = "Log") throws -> (Note, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-settle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(name).md")
        try Data(body.utf8).write(to: url)
        return (Note(title: name, fileURL: url, lastModified: Date(), fileSize: body.utf8.count), dir)
    }

    /// An editor on `note`, its live document, and the load that matched them —
    /// with the model's flush carrying the document, as the host sets it.
    private func liveEditor(on note: Note) async -> (EditorModel, EditorDocument, DocumentLoad) {
        let editor = EditorModel()
        await editor.open(note)
        let document = EditorDocument(text: editor.text)
        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)
        editor.willFlush = { [weak editor] in
            guard let editor else { return }
            load.carry(document, into: editor)
        }
        return (editor, document, load)
    }

    private func onDisk(_ note: Note) throws -> String { try String(contentsOf: note.fileURL, encoding: .utf8) }

    /// Typed, then away to another tab and back. Nothing ends editing on a tab
    /// switch — the Mac's tab bar takes no focus and the text view is only
    /// rebound, and on iPad the text view is removed without saying so — so
    /// what was typed was still only in the document, and coming back the host
    /// replaced the document with the buffer that had never seen it.
    @Test func typingSurvivesATabSwitchAndReturn() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        if let leaving = load.settleOnLeaving(document) { await leaving.save() }
        _ = load.settleOnReturn(document, to: editor)

        #expect(document.text == "# Log\n\nAs it was. Typed.\n", "the typing was replaced on the way back")
        #expect(editor.text == "# Log\n\nAs it was. Typed.\n", "the typing never reached the buffer")
        #expect(try onDisk(note) == "# Log\n\nAs it was. Typed.\n", "switching away did not save it")
    }

    /// A tag accepted while something typed has not been carried yet: the
    /// write is made to what is on screen, the document shows it, and typing
    /// on does not take it away again. It went into the buffer alone, never
    /// reached the document, and the next carry wrote the document — without
    /// the tag — over it.
    @Test func anAppWriteReachesTheDocumentAndSurvivesTyping() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        editor.applyEdit { NoteEdits.addingTag("tour", to: $0) }
        _ = load.settleWithBuffer(document, editor)      // the host follows `textVersion`
        #expect(document.text.contains("tour"), "the tag never reached the document on screen")
        #expect(document.text.contains("Typed."), "the write was made to an older copy of the note")

        document.replaceFirst("Typed.", with: "Typed. More.")
        editor.willFlush?()
        await editor.save()
        let saved = try onDisk(note)
        #expect(saved.contains("tour"), "typing on took the tag away again")
        #expect(saved.contains("Typed. More."))
    }

    /// Typed, not yet carried, and the file changes elsewhere: that is a
    /// conflict. It was a silent reload — `isDirty` could not see what was
    /// never carried — and the host then put the other version over the typing.
    @Test func aChangeElsewhereWhileTypingIsAConflictNotAReload() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        try Data("# Log\n\nChanged elsewhere.\n".utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        _ = load.settleWithBuffer(document, editor)      // the host follows the load

        #expect(editor.hasConflict, "a change elsewhere was loaded silently over unsaved typing")
        #expect(document.text == "# Log\n\nAs it was. Typed.\n", "the typing on screen was replaced")
    }

    /// A tab whose note has left the list is kept while it holds unsaved work
    /// — and typing not yet carried is unsaved work. It was pruned.
    @Test func pruningKeepsATabWithTypingNotYetCarried() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tabs = EditorTabs()
        let editor = await tabs.editor(for: note)
        let document = EditorDocument(text: editor.text)
        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)
        editor.willFlush = { [weak editor] in
            guard let editor else { return }
            load.carry(document, into: editor)
        }

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        tabs.prune(keeping: [])
        #expect(tabs.editors.contains { $0 === editor }, "a tab with typing not yet carried was pruned")
        #expect(editor.text.contains("Typed."))
    }

    /// The store forgetting a document it kept — the set of notes changed, a
    /// tab was switched away from — first carries what was typed into it into
    /// its buffer. It was dropped, typing and all.
    @Test func forgettingAKeptDocumentCarriesItsTypingFirst() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)
        let store = EditorDocumentStore()
        store.insert(document, for: key(note, editor))
        store.remember(load, for: key(note, editor))

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        store.forgetAll(except: nil)
        #expect(editor.text.contains("Typed."), "the store dropped a document whose typing was never carried")
    }

    /// A note open in two windows — a tab in one, Open in New Window in the
    /// other — has an editor in each. The store is the app's, and its key named
    /// the note but not the editor, so the second window was handed the
    /// first's document and its load: it replaced what the first had typed
    /// with its own buffer, and took the load over, so the first window's end
    /// of editing carried into the second window's buffer.
    @Test func aNoteOpenInTwoWindowsKeepsADocumentForEach() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EditorDocumentStore()
        let (first, document, load) = await liveEditor(on: note)
        store.insert(document, for: key(note, first))
        store.remember(load, for: key(note, first))
        document.replaceFirst("As it was.", with: "As it was. Typed in the first window.")

        // The second window's host starting, as the host does: a kept
        // document settled with its buffer, or a new one.
        let second = EditorModel()
        await second.open(note)
        if let kept = store.document(for: key(note, second)) {
            let keptLoad = store.load(for: key(note, second)) ?? DocumentLoad(revision: second.loadRevision)
            _ = keptLoad.settleOnReturn(kept, to: second)
            keptLoad.revision = second.loadRevision
            keptLoad.matched(kept, second)
        }
        #expect(document.text.contains("Typed in the first window."), "the second window replaced the first window's typing")
        #expect(load.model === first, "the first window's document now carries into the second window's buffer")
    }

    /// The key the host builds for `editor`'s note.
    private func key(_ note: Note, _ editor: EditorModel) -> EditorDocumentStore.Key {
        EditorDocumentStore.Key(path: note.fileURL.path, editor: editor.editorID,
                                fontSize: 13, isDark: false, accent: "-")
    }

    /// Both moved, and a load is one of them — the person chose Reload, or a
    /// load landed while typing was on screen: the load wins. A load is the
    /// file's text.
    @Test func whenBothMovedALoadWins() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)
        document.replaceFirst("As it was.", with: "As it was. Mine.")
        editor.willFlush?()
        try Data("# Log\n\nTheirs.\n".utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict)

        document.replaceFirst("Mine.", with: "Mine. More.")
        await editor.resolveConflictReloading()
        _ = load.settleWithBuffer(document, editor)
        #expect(document.text == "# Log\n\nTheirs.\n", "the reload that was chosen did not reach the document")
    }

    /// Both moved and no load is involved — a write into the buffer that did
    /// not go through `applyEdit`, so it was made to an older copy: the typing
    /// wins. It is on screen and in no undo stack once replaced, where a write
    /// the app made can be made again.
    @Test func whenBothMovedWithoutALoadTheTypingWins() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)
        document.replaceFirst("As it was.", with: "As it was. Typed.")
        editor.text = Self.body + "Written without carrying first.\n"

        _ = load.settleWithBuffer(document, editor)
        #expect(document.text == "# Log\n\nAs it was. Typed.\n", "the typing on screen was replaced")
        #expect(editor.text == "# Log\n\nAs it was. Typed.\n", "the buffer does not hold what is on screen")
    }

    /// Settling reads neither text to compare them. Which side moved is in the
    /// counts; the host compared the document's bridged string with the buffer
    /// instead, on the main actor, on every tab switch back and every reload.
    @Test func settlingComparesNothingOnTheMainActor() async throws {
        let (note, dir) = try makeNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)
        let buffer = MainThreadReads(text: Self.body)
        #expect(editor.adopt(buffer as String, fromLoad: editor.loadRevision))
        load.matched(document, editor)

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        _ = load.settleOnReturn(document, to: editor)
        #expect(buffer.onMain == 0, "settling compared the buffer on the main actor \(buffer.onMain) times")
        #expect(editor.text == "# Log\n\nAs it was. Typed.\n")
    }

    // MARK: - The Properties panel

    private static let withProperties = "---\ntags: [tour, demo]\npriority: 2\n---\n\n# Log\n\nAs it was.\n"

    /// A field in the Properties panel hands its value back when it gains
    /// focus, unchanged, and the panel writes whatever it is handed. Rendered
    /// again, that rewrote the front matter in the panel's own style — `tags:
    /// [tour, demo]` became a block list, a write and a save for a tap — and
    /// now that a write the app makes reaches the document, it replaced the
    /// note on screen and cleared its undo too.
    @Test func handingBackUnchangedPropertiesChangesNothing() async throws {
        let (note, dir) = try makeNote(Self.withProperties)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)
        let generation = editor.textGeneration

        editor.setProperties(FrontMatter.properties(in: editor.text))
        #expect(editor.textGeneration == generation, "an unchanged write moved the buffer")
        #expect(load.settleWithBuffer(document, editor) == nil, "an unchanged write replaced the document on screen")
        #expect(editor.text == Self.withProperties, "the front matter was rewritten although nothing changed")
    }

    /// The negative control, and the change the panel exists for: a property
    /// changed while typing is on screen reaches the document with the typing
    /// in it, and typing on keeps it.
    @Test func aChangedPropertyReachesTheDocumentAndStays() async throws {
        let (note, dir) = try makeNote(Self.withProperties)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (editor, document, load) = await liveEditor(on: note)

        document.replaceFirst("As it was.", with: "As it was. Typed.")
        var properties = FrontMatter.properties(in: editor.text)
        let priority = try #require(properties.firstIndex { $0.key == "priority" })
        properties[priority].text = "3"
        editor.setProperties(properties)
        #expect(load.settleWithBuffer(document, editor) != nil, "the change never reached the document")
        #expect(document.text.contains("priority: 3"))
        #expect(document.text.contains("As it was. Typed."), "the change was made to an older copy of the note")

        document.replaceFirst("Typed.", with: "Typed. More.")
        editor.willFlush?()
        await editor.save()
        let saved = try onDisk(note)
        #expect(saved.contains("priority: 3"), "typing on took the property away again")
        #expect(saved.contains("As it was. Typed. More."))
    }

    /// A write the app makes lands in the front matter — a property, a tag, a
    /// link, a summary — above a caret in the body. Replacing the document put
    /// the caret back at its old offset, so it moved by as much as the front
    /// matter grew: seven characters for a priority of 250 in a note whose tags
    /// the panel wrote back as a list, and what was typed next went into the
    /// middle of a word. Only the key that changed is written now (§51.26), so
    /// the growth is the value's own two characters — still a move the caret
    /// must make. The control: a caret in the front matter stays put.
    @Test func aWriteAboveTheCaretKeepsItsPlaceInTheBody() throws {
        let old = Self.withProperties
        var properties = FrontMatter.properties(in: old)
        let priority = try #require(properties.firstIndex { $0.key == "priority" })
        properties[priority].text = "250"
        let new = FrontMatter.applying(properties, to: old)
        let bodyWas = FrontMatter.bodyOffset(in: old)
        let bodyIs = FrontMatter.bodyOffset(in: new)
        #expect(bodyIs == bodyWas + 2, "a change to one key rewrote others: \(new.debugDescription)")

        let typing = NSRange(location: NSMaxRange((old as NSString).range(of: "As it")), length: 0)
        let moved = DocumentLoad.caret(typing, bodyWas: bodyWas, bodyIs: bodyIs)
        #expect((new as NSString).substring(to: moved.location).hasSuffix("As it"),
                "the caret moved \(moved.location - typing.location - 2) characters within the body")

        let inFrontMatter = NSRange(location: 5, length: 0)
        #expect(DocumentLoad.caret(inFrontMatter, bodyWas: bodyWas, bodyIs: bodyIs) == inFrontMatter)
    }

    /// The panel lists its rows by `Property.id`. A fresh `UUID` on every
    /// parse made every row a new one whenever the note changed — each
    /// keystroke in a field, and the value a field hands back on gaining focus
    /// — so SwiftUI tore down the field being typed in: on iPad a tap on one
    /// never kept the keyboard. Identity is the key, and a key that appears
    /// twice (hand-written YAML) is still two rows.
    @Test func aPropertyKeepsItsIdentityWhenItsValueChanges() {
        let before = FrontMatter.properties(in: Self.withProperties).map(\.id)
        let after = FrontMatter.properties(
            in: Self.withProperties.replacingOccurrences(of: "priority: 2", with: "priority: 3")
        ).map(\.id)
        #expect(before == after, "a row became a new row when its value changed")

        let twice = FrontMatter.properties(in: "---\ntag: a\ntag: b\n---\n").map(\.id)
        #expect(twice.count == 2 && Set(twice).count == 2, "two rows shared one identity")
    }
}

//
//  SaveOffMainTests.swift
//  HelloNotesTests
//
//  A save never reads the note on the main actor.
//
//  It used to compare the whole note there four times — the editor's copy with
//  the buffer (`adopt`), the buffer with the file whenever the buffer changed
//  (`text.didSet`), and again on the way into the save and into the write —
//  and then encode it, still there; and `@Observable`'s own setter made a
//  fifth, of every new text with the old one. The editor's copy is a bridged
//  `NSString`, whose comparison costs 31–57 ms a megabyte, so letting go of a
//  large note froze the editor for a tenth of a second or more; and Markdown
//  and Split mode write the buffer on every keystroke, so two of those ran
//  once per key.
//
//  Dirtiness is a count now — the buffer's generation against the one the file
//  holds — and the one comparison that has to happen, whether the bytes differ
//  from the file's, is made inside the write, off the main actor.
//

import Testing
import Foundation
import Observation
import os
import MarkdownEditor
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@Suite @MainActor
struct SaveOffMainTests {

    private func makeNote(_ body: String) throws -> (Note, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Log.md")
        try Data(body.utf8).write(to: url)
        return (Note(title: "Log", fileURL: url, lastModified: Date(), fileSize: body.utf8.count), dir)
    }

    /// Large enough to matter and not ASCII, so nothing about it is cheap to
    /// compare by accident.
    private static let typed = String(repeating: "Typed into the note — café, naïve, 日本語.\n", count: 2_000)

    /// The whole save — the editor's copy taken, the buffer marked, the check
    /// against the file and the write — reads the note on the main actor zero
    /// times, and still writes it.
    @Test func aSaveNeverReadsTheNoteOnTheMainActor() async throws {
        let (note, dir) = try makeNote("# Log\n\nAs it was.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)

        let copy = MainThreadReads(text: Self.typed)
        #expect(editor.adopt(copy as String, fromLoad: editor.loadRevision))
        #expect(editor.isDirty)
        await editor.save()

        #expect(copy.onMain == 0, "the save read the note on the main actor \(copy.onMain) times")
        #expect(!editor.isDirty)
        #expect(try Data(contentsOf: note.fileURL) == Data(Self.typed.utf8), "and did not write it")
    }

    /// The control: the probe sees the comparison `adopt` used to make. Without
    /// it, the zero above could mean only that the probe sees nothing.
    @Test func theProbeSeesAComparisonMadeOnTheMainActor() {
        let copy = MainThreadReads(text: "# Log\n\nTyped here.\n")
        let buffer = "# Log\n\nAs it was!!\n"
        #expect(buffer != copy as String)
        #expect(copy.onMain > 0, "a comparison on the main actor went unseen, so a zero proves nothing")
    }

    /// A copy that is the file's bytes is not written again. The question is
    /// still asked — off the main actor now — and the file is left alone: no
    /// write, no `onSaved`, no new revision. A copy that differs is written.
    @Test func aCopyThatIsTheFileIsNotWrittenAgain() async throws {
        let body = "# Log\n\nAs it was — café.\n"
        let (note, dir) = try makeNote(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        var saved: [String] = []
        editor.onSaved = { _, text in saved.append(text) }

        let same = MainThreadReads(text: body)
        #expect(editor.adopt(same as String, fromLoad: editor.loadRevision))
        await editor.save()
        #expect(saved.isEmpty && editor.savedRevision == 0, "the file's own bytes were written back over it")
        #expect(!editor.isDirty)
        #expect(same.onMain == 0)

        // The control: a copy that differs is written.
        #expect(editor.adopt(body + "More.\n", fromLoad: editor.loadRevision))
        await editor.save()
        #expect(saved == [body + "More.\n"] && editor.savedRevision == 1)
        #expect(try Data(contentsOf: note.fileURL) == Data((body + "More.\n").utf8))
    }

    /// Bytes, not canonical equivalence. `==` calls a precomposed é and an e
    /// with a combining accent equal, and they are two different files — so a
    /// buffer that changed only that way was never saved.
    @Test func aChangeOfNormalisationIsSaved() async throws {
        let (note, dir) = try makeNote("Caf\u{E9}\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)

        #expect(editor.adopt("Cafe\u{301}\n", fromLoad: editor.loadRevision))
        await editor.save()
        #expect(try Data(contentsOf: note.fileURL) == Data("Cafe\u{301}\n".utf8),
                "a change of normalisation compared equal and was not saved")
    }

    /// Checking the file after an external change compares it with the last
    /// save — the whole note — off the main actor as well. The change is still
    /// found, and a file that still holds the last save is still no change.
    @Test func anExternalChangeIsCheckedOffTheMainActor() async throws {
        let (note, dir) = try makeNote("# Log\n\nAs it was.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        let copy = MainThreadReads(text: Self.typed)
        editor.adopt(copy as String, fromLoad: editor.loadRevision)
        await editor.save()

        // The file still says what was saved: nothing to do.
        await editor.reconcileWithDisk()
        #expect(!editor.hasConflict && editor.loadRevision == 1)

        try Data("Changed elsewhere.\n".utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(copy.onMain == 0, "checking the file read the last save on the main actor \(copy.onMain) times")
        #expect(editor.text == "Changed elsewhere.\n" && !editor.hasConflict)
    }

    /// A buffer typed back to what was last saved is dirty by the count and
    /// not in fact. A change made elsewhere is then taken, as it always was —
    /// not raised as a conflict between the file and a copy of itself.
    @Test func aBufferTypedBackToTheLastSaveTakesAChangeElsewhere() async throws {
        let (note, dir) = try makeNote("# Log\n\nAs it was.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        editor.text = "# Log\n\nAs it was. Typed.\n"
        editor.text = "# Log\n\nAs it was.\n"
        #expect(editor.isDirty, "typed and deleted is a change to the count until a save finds otherwise")

        try Data("Changed elsewhere.\n".utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(!editor.hasConflict, "nothing of the person's differed from the file, and a conflict was raised")
        #expect(editor.text == "Changed elsewhere.\n" && !editor.isDirty)
    }

    /// Keep Mine writes mine — even when mine is, byte for byte, what was last
    /// saved, because the file now holds theirs. It used to compare the buffer
    /// with the last save, find them equal, write nothing, and call the note
    /// saved while the file said something else.
    @Test func keepingMineWritesMineEvenWhenItIsWhatWasLastSaved() async throws {
        let (note, dir) = try makeNote("# Log\n\nAs it was.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        editor.text = "# Log\n\nMine.\n"
        try Data("Theirs.\n".utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict)

        editor.text = "# Log\n\nAs it was.\n"
        await editor.resolveConflictKeepingMine()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "# Log\n\nAs it was.\n",
                "Keep Mine wrote nothing, and the file kept theirs")
        #expect(!editor.isDirty && !editor.hasConflict)
    }

    /// The control: Keep Mine with a buffer unlike either writes it.
    @Test func keepingMineWritesMine() async throws {
        let (note, dir) = try makeNote("# Log\n\nAs it was.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        editor.text = "# Log\n\nMine.\n"
        try Data("Theirs.\n".utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict)
        await editor.resolveConflictKeepingMine()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "# Log\n\nMine.\n")
    }

    /// An edit made in place — `editor.text += …`, Insert Template's way — is
    /// an edit like any other: the buffer is dirty, counted once, and whoever
    /// reads the text hears about it. (`text` is observed by hand, so its
    /// in-place accessor is written by hand too.)
    @Test func anEditInPlaceIsAnEdit() async throws {
        let (note, dir) = try makeNote("# Log\n\nAs it was.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        let before = editor.textGeneration
        let heard = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = editor.text } onChange: { heard.withLock { $0 = true } }

        editor.text += "Appended.\n"
        #expect(editor.text == "# Log\n\nAs it was.\nAppended.\n")
        #expect(editor.textGeneration == before + 1 && editor.isDirty)
        #expect(heard.withLock { $0 }, "an edit in place went unheard by what reads the text")
        await editor.save()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "# Log\n\nAs it was.\nAppended.\n")
    }

    /// Publishing the buffer to the other scenes after a save — a note, then
    /// the same note again once the burst ends — reads neither text on the main
    /// actor. `@Observable`'s own setter compared the old with the new.
    @Test func publishingTheBufferReadsNothingOnTheMainActor() async throws {
        let live = LiveBuffer()
        let url = URL(fileURLWithPath: "/tmp/Log.md")
        let first = MainThreadReads(text: Self.typed)
        let second = MainThreadReads(text: Self.typed + "More.\n")
        live.publish(url: url, text: first as String)
        live.publish(url: url, text: second as String)
        for _ in 0..<100 where live.text(for: url).map({ ($0 as NSString) !== second }) ?? true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(live.text(for: url).map { ($0 as NSString) === second } == true, "the second text was never published")
        #expect(first.onMain == 0 && second.onMain == 0,
                "publishing read the note on the main actor \(first.onMain + second.onMain) times")
    }
}

/// What a settle carries from the editor's document into the buffer, decided
/// without comparing the two: the document's own revision, and the buffer's
/// generation, against the moment they last held the same text.
@Suite @MainActor
struct DocumentCarryTests {

    private func makeNote(_ body: String) throws -> (Note, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-carry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Start Here.md")
        try Data(body.utf8).write(to: url)
        return (Note(title: "Start Here", fileURL: url, lastModified: Date(), fileSize: body.utf8.count), dir)
    }

    /// Nothing typed, nothing carried — the buffer is not even set. Something
    /// typed is carried, once. And a replacement the host makes to bring the
    /// document up to date is matched, so it is not taken back as an edit.
    @Test func aSettleCarriesWhatWasTypedAndNothingElse() async throws {
        let (note, dir) = try makeNote("# Start Here\n\nA five-minute tour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        let document = EditorDocument(text: editor.text)
        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)

        let untouched = editor.textGeneration
        #expect(load.carry(document, into: editor))
        #expect(editor.textGeneration == untouched && !editor.isDirty, "an untouched document was carried")

        document.replaceFirst("tour.", with: "tour. Typed.")
        #expect(load.carry(document, into: editor))
        #expect(editor.text == "# Start Here\n\nA five-minute tour. Typed.\n" && editor.isDirty,
                "what was typed was not carried")
        let carried = editor.textGeneration
        #expect(load.carry(document, into: editor))
        #expect(editor.textGeneration == carried, "the same edit was carried twice")

        document.replaceText("# Start Here\n\nReloaded.\n")
        load.matched(document, editor)
        #expect(load.carry(document, into: editor))
        #expect(editor.text == "# Start Here\n\nA five-minute tour. Typed.\n",
                "a replacement made by the host was taken back as an edit")
    }

    /// The Start Here rule still holds through `carry`: a document made from an
    /// earlier load is refused once it has been edited, and carries nothing
    /// before that — and the note on disk is left alone either way.
    @Test func aDocumentFromAnEarlierLoadIsStillRefused() async throws {
        let (note, dir) = try makeNote("# Start Here\n\nA five-minute tour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        editor.willOpen(note)
        let document = EditorDocument(text: editor.text)
        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)
        await editor.open(note)

        #expect(load.carry(document, into: editor))
        document.replaceText("Typed.")
        #expect(!load.carry(document, into: editor), "a copy of an earlier load was taken")
        await editor.flush()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "# Start Here\n\nA five-minute tour.\n")
    }

    /// A document built while the note was still loading is brought up to date
    /// when the load lands during the build, so what is typed next is typed
    /// into the note.
    @Test func aDocumentBuiltBeforeTheLoadLandedIsBroughtUpToDate() async throws {
        let (note, dir) = try makeNote("# Start Here\n\nA five-minute tour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        editor.willOpen(note)
        let generation = editor.textGeneration
        let document = EditorDocument(text: editor.text)
        await editor.open(note)

        let load = DocumentLoad(built: document, at: generation, for: editor)
        #expect(document.text == editor.text)
        document.replaceFirst("tour.", with: "tour. Typed.")
        #expect(load.carry(document, into: editor))
        await editor.flush()
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8)
                == "# Start Here\n\nA five-minute tour. Typed.\n")
    }

    /// The control: the same document matched as built, without being brought
    /// up to date, carries what was typed into it — and nothing of the note —
    /// over the buffer. This is the loss the test above guards against.
    @Test func matchedAsBuiltTheTypingReplacesTheNote() async throws {
        let (note, dir) = try makeNote("# Start Here\n\nA five-minute tour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        editor.willOpen(note)
        let document = EditorDocument(text: editor.text)
        await editor.open(note)

        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)
        document.replaceText("Typed.")
        #expect(load.carry(document, into: editor))
        #expect(editor.text == "Typed.", "the stale document no longer replaces the note, so the test above proves nothing")
    }

    /// A document is carried only into the buffer it was matched with, by the
    /// load it was matched under. A tab switch can hand the host one tab's
    /// document beside another's model and load for a moment, and every count
    /// in that pairing can agree by accident — both first loads are load 1 —
    /// so the pairing itself is what is checked.
    @Test func aDocumentIsCarriedOnlyIntoItsOwnBuffer() async throws {
        let (noteA, dirA) = try makeNote("# A\n\nFirst tab.\n")
        let (noteB, dirB) = try makeNote("# B\n\nSecond tab.\n")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let editorA = EditorModel(), editorB = EditorModel()
        await editorA.open(noteA)
        await editorB.open(noteB)
        let documentA = EditorDocument(text: editorA.text), documentB = EditorDocument(text: editorB.text)
        let loadA = DocumentLoad(revision: editorA.loadRevision), loadB = DocumentLoad(revision: editorB.loadRevision)
        loadA.matched(documentA, editorA)
        loadB.matched(documentB, editorB)
        #expect(editorA.loadRevision == editorB.loadRevision, "the loads differ, so this is not the pairing that slips through")
        documentA.replaceFirst("First tab.", with: "First tab. Typed in A.")

        #expect(!loadB.carry(documentA, into: editorB), "B's load took A's document")
        #expect(!loadA.carry(documentA, into: editorB), "A's document went into B's buffer")
        #expect(editorB.text == "# B\n\nSecond tab.\n", "B's note now holds A's text")

        // The control: the pair it was matched with is carried.
        #expect(loadA.carry(documentA, into: editorA))
        #expect(editorA.text == "# A\n\nFirst tab. Typed in A.\n")
    }

    /// A kept document matches its buffer until either side moves: an edit in
    /// the document, a write by the app into the buffer — and never another
    /// tab's buffer, whose count can be the same number.
    @Test func aKeptDocumentMatchesUntilEitherSideMoves() async throws {
        let (note, dir) = try makeNote("# Start Here\n\nA five-minute tour.\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = EditorModel()
        await editor.open(note)
        let other = EditorModel()
        await other.open(note)
        let document = EditorDocument(text: editor.text)
        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)

        #expect(load.stillMatches(document, editor))
        #expect(other.textGeneration == editor.textGeneration)
        #expect(!load.stillMatches(document, other), "another tab's buffer matched")

        editor.text += "\nA tag the app wrote.\n"
        #expect(!load.stillMatches(document, editor), "a write into the buffer went unseen")

        load.matched(document, editor)
        document.replaceFirst("tour.", with: "tour. Typed.")
        #expect(!load.stillMatches(document, editor), "an edit in the document went unseen")
    }
}

/// A note's text that counts where it is read: an `NSString`, as the copy an
/// editor hands the model is (`EditorDocument.text` is its storage's string),
/// recording each read of its characters made on the main thread.
///
/// Every way into an `NSString`'s characters ends at one of its two
/// primitives, so counting those counts them all.
nonisolated final class MainThreadReads: NSString, @unchecked Sendable {
    private let backing: NSString
    private let lock = NSLock()
    private var reads = 0

    /// Labelled on purpose: `MainThreadReads("…")` would be read as a string
    /// literal of this type (SE-0213) and go through `NSString`'s literal
    /// initialiser, which a subclass cannot serve.
    init(text: String) {
        backing = NSString(string: text)
        super.init()
    }

    override init() {
        backing = ""
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    #if canImport(AppKit)
    /// AppKit makes every `NSString` pasteboard-readable, and so every
    /// subclass; with this, every designated initialiser is covered and the
    /// literal initialisers are inherited.
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        backing = NSString(string: (propertyList as? String) ?? "")
        super.init()
    }
    #else
    // UIKit asks nothing more of a subclass.
    #endif

    /// Reads of its characters made on the main thread so far.
    var onMain: Int { lock.withLock { reads } }

    override var length: Int { backing.length }

    override func character(at index: Int) -> unichar {
        noteRead()
        return backing.character(at: index)
    }

    override func getCharacters(_ buffer: UnsafeMutablePointer<unichar>, range: NSRange) {
        noteRead()
        backing.getCharacters(buffer, range: range)
    }

    /// Immutable, so a copy is itself — which keeps a bridged `String` reading
    /// this object rather than a copy the bridge made.
    override func copy(with zone: NSZone? = nil) -> Any { self }

    private func noteRead() {
        guard Thread.isMainThread else { return }
        lock.withLock { reads += 1 }
    }
}

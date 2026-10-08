//
//  ConflictSaveTests.swift
//  HelloNotesTests
//
//  While the banner says the note changed on disk, the note's file holds
//  theirs, and only Keep Mine may put mine there. Every other moment the
//  buffer is saved — the end of editing, a tab switch, the app going to the
//  background — wrote it over theirs as if Keep Mine had been chosen; and a
//  Reload afterwards took theirs into the buffer and called it clean while the
//  file held mine, so the next look at the file loaded mine back.
//
//  Letting go of a buffer that holds a conflict — quitting, closing its tab or
//  window, opening another note in its editor — neither writes mine over
//  theirs nor drops it: mine is kept beside the note, as a conflicted copy.
//

import Testing
import Foundation
import MarkdownEditor
@testable import HelloNotes

@Suite @MainActor
struct ConflictSaveTests {

    private static let original = "# Log\n\nAs it was.\n"
    private static let mine = "# Log\n\nMine.\n"
    private static let theirs = "# Log\n\nTheirs.\n"

    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeNote(named name: String = "Log", _ body: String = Self.original, in dir: URL) throws -> Note {
        let url = dir.appending(path: "\(name).md")
        try Data(body.utf8).write(to: url)
        return Note(title: name, fileURL: url, lastModified: Date(), fileSize: body.utf8.count)
    }

    /// Mine typed into `editor`, theirs written over the file elsewhere, and
    /// the file checked: the banner is up.
    private func conflict(in editor: EditorModel, on note: Note) async throws {
        editor.text = Self.mine
        try Data(Self.theirs.utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict, "no conflict was raised to test")
    }

    private func onDisk(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// The conflicted copies kept beside `note`.
    private func copies(of note: Note) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: note.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(note.title) (conflicted copy ") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A settle while the banner is up — the end of editing, a tab switch, the
    /// app going to the background — wrote the buffer over theirs, as if Keep
    /// Mine had been chosen. The file keeps theirs, and the buffer stays
    /// dirty: mine is still the person's to keep.
    @Test func aSaveWhileAConflictIsOpenWritesNothing() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        await editor.save()
        #expect(try onDisk(note.fileURL) == Self.theirs, "a save while the conflict was open wrote mine over theirs")
        #expect(editor.isDirty, "mine was marked saved")
        #expect(editor.hasConflict)
    }

    /// Reload after such a save took theirs into the buffer and called it
    /// clean while the file held mine: theirs was never written back, and the
    /// next look at the file loaded mine again, without a word.
    @Test func reloadingLeavesTheirsInTheFile() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        await editor.save()
        await editor.resolveConflictReloading()
        #expect(editor.text == Self.theirs && !editor.isDirty && !editor.hasConflict)
        #expect(try onDisk(note.fileURL) == Self.theirs, "Reload called theirs clean while the file held mine")
        await editor.reconcileWithDisk()
        #expect(editor.text == Self.theirs, "the next look at the file put mine back")
    }

    /// The control: Keep Mine is how mine lands — after a settle that wrote
    /// nothing, it writes it, and keeps no copy.
    @Test func keepingMineIsHowMineLands() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        await editor.save()
        await editor.resolveConflictKeepingMine()
        #expect(try onDisk(note.fileURL) == Self.mine)
        #expect(!editor.isDirty && !editor.hasConflict)
        #expect(try copies(of: note).isEmpty)
    }

    /// Letting go of the buffer with the banner up — the app quitting, the
    /// buffer about to be dropped — keeps mine beside the note, and leaves
    /// theirs in it. A save put mine over theirs; not saving would lose mine
    /// with the buffer.
    @Test func lettingGoKeepsMineBesideTheNote() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        await editor.flush()
        #expect(try onDisk(note.fileURL) == Self.theirs, "letting go wrote mine over theirs")
        let kept = try copies(of: note)
        #expect(kept.count == 1, "mine was not kept anywhere")
        let copy = try #require(kept.first)
        let stamp = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        #expect(copy.lastPathComponent == "Log (conflicted copy \(stamp)).md")
        #expect(try onDisk(copy) == Self.mine)
        #expect(editor.hasConflict && editor.isDirty, "the choice is still the person's")
    }

    /// One copy per conflict, kept current as mine changes — and never
    /// written over what someone else put in it: that makes it theirs, and
    /// mine goes into a copy of its own.
    @Test func aCopyIsKeptCurrentAndNeverWrittenOverAnEdit() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        await editor.flush()
        editor.text = Self.mine + "More.\n"
        await editor.flush()
        let first = try #require(try copies(of: note).first)
        #expect(try copies(of: note).count == 1, "a second copy was made for the same conflict")
        #expect(try onDisk(first) == Self.mine + "More.\n", "the copy was not kept current")

        try Data("Edited by hand.\n".utf8).write(to: first)
        editor.text = Self.mine + "More still.\n"
        await editor.flush()
        let kept = try copies(of: note)
        #expect(kept.count == 2)
        #expect(Set(try kept.map { try onDisk($0) }) == ["Edited by hand.\n", Self.mine + "More still.\n"],
                "an edit made to the copy was written over")
    }

    /// The control for letting go: a flush that keeps the buffer — a switch of
    /// mode, a rename, the Mac going to the background — writes nothing
    /// anywhere while a conflict is open, and the choice stays open.
    @Test func aFlushThatKeepsTheBufferWritesNothingAnywhere() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let tabs = EditorTabs()
        let editor = await tabs.editor(for: note)
        try await conflict(in: editor, on: note)

        await editor.flush(lettingGo: false)
        await tabs.flushAll(lettingGo: false)
        #expect(try onDisk(note.fileURL) == Self.theirs)
        #expect(try copies(of: note).isEmpty, "a copy was made of a buffer nobody let go of")
        #expect(editor.hasConflict && editor.isDirty && editor.text == Self.mine)
    }

    /// A copy is created, never written over a file already there — the cloud
    /// mirror keeps its own conflicted copies under the same kind of name.
    @Test func aCopyNeverReplacesAFileAlreadyThere() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let stamp = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let taken = dir.appending(path: "Log (conflicted copy \(stamp)).md")
        try Data("Already here.\n".utf8).write(to: taken)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        await editor.flush()
        #expect(try onDisk(taken) == "Already here.\n", "a file already there was written over")
        #expect(try onDisk(dir.appending(path: "Log (conflicted copy \(stamp) 2).md")) == Self.mine)
    }

    /// Keep Mine keeps what is on screen: typing the live editor holds and the
    /// buffer has not yet taken goes with it.
    @Test func keepingMineKeepsWhatIsOnScreen() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        let document = EditorDocument(text: editor.text)
        let load = DocumentLoad(revision: editor.loadRevision)
        load.matched(document, editor)
        editor.willFlush = { [weak editor] in
            guard let editor else { return }
            load.carry(document, into: editor)
        }
        document.replaceFirst("As it was.", with: "Mine.")
        try Data(Self.theirs.utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict)

        document.replaceFirst("Mine.", with: "Mine, and more.")
        await editor.resolveConflictKeepingMine()
        #expect(try onDisk(note.fileURL) == "# Log\n\nMine, and more.\n", "Keep Mine left out what was on screen")
    }

    /// A save writes only over the file it last saw. It replaced whatever was
    /// there, so a change made elsewhere since the last look — no conflict
    /// raised yet, the watcher not yet round to it — was written over at the
    /// next save; and a save already past its checks when a change was
    /// noticed put mine over theirs with the banner up. The change stays,
    /// mine stays dirty, and the save's own look at the file raises the
    /// conflict.
    @Test func aSaveNeverWritesOverAChangeItHasNotSeen() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        editor.text = Self.mine
        try Data(Self.theirs.utf8).write(to: note.fileURL)

        await editor.save()
        #expect(try onDisk(note.fileURL) == Self.theirs, "the save wrote over a change it had not seen")
        #expect(editor.isDirty)
        #expect(editor.hasConflict, "the change the save found was not raised")
    }

    /// A buffer let go — its tab or window closing, the app quitting — whose
    /// own save finds a change it had not seen keeps mine beside the note, as a
    /// let-go with a conflict already open does. The flush asked about a
    /// conflict only before saving: the save raised one and returned, the flush
    /// said the buffer was saved, and the caller dropped it — what was typed was
    /// gone, and no copy of it kept.
    @Test func aBufferLetGoWhoseSaveFindsAChangeKeepsMineBesideTheNote() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        editor.text = Self.mine
        try Data(Self.theirs.utf8).write(to: note.fileURL)

        let dropped = await editor.flush(lettingGo: true)
        #expect(try onDisk(note.fileURL) == Self.theirs, "the flush wrote over a change it had not seen")
        let kept = try copies(of: note)
        #expect(kept.count == 1, "mine was let go with the buffer: no conflicted copy was kept")
        if let copy = kept.first { #expect(try onDisk(copy) == Self.mine) }
        #expect(dropped, "the buffer was kept from being let go though mine was kept beside the note")
    }

    /// The control: the same flush, not letting go — a switch of mode, a
    /// rename — keeps the buffer, raises the conflict, and writes nothing
    /// anywhere.
    @Test func aBufferKeptWhoseSaveFindsAChangeWritesNothingAnywhere() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        editor.text = Self.mine
        try Data(Self.theirs.utf8).write(to: note.fileURL)

        await editor.flush(lettingGo: false)
        #expect(try onDisk(note.fileURL) == Self.theirs)
        #expect(editor.hasConflict && editor.isDirty && editor.text == Self.mine)
        #expect(try copies(of: note).isEmpty, "a flush that keeps the buffer wrote a conflicted copy")
    }

    /// With a conflict open, a newer change is the same conflict with a newer
    /// theirs — never taken silently. Taken (the buffer typed back to the last
    /// save looked clean), it moved into the buffer under a banner still
    /// holding the older theirs, and Reload put the older back over it.
    @Test func aNewerChangeUnderAnOpenConflictIsNeverTakenSilently() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        editor.text = Self.original
        let newer = "# Log\n\nTheirs, newer.\n"
        try Data(newer.utf8).write(to: note.fileURL)
        await editor.reconcileWithDisk()
        #expect(editor.hasConflict)
        #expect(editor.text == Self.original, "the newer change was taken into the buffer under the banner")

        await editor.resolveConflictReloading()
        #expect(try onDisk(note.fileURL) == newer, "Reload put the older theirs back")
        #expect(editor.text == newer)
    }

    /// Two let-gos at once keep one copy. iOS drains once for resigning active
    /// and again for each change of scene phase; both saw no copy yet, and
    /// each made one.
    @Test func twoLetGosAtOnceKeepOneCopy() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        async let first = editor.flush()
        async let second = editor.flush()
        let kept = await (first, second)
        #expect(kept.0 && kept.1)
        #expect(try copies(of: note).count == 1, "two let-gos at once kept two copies")
    }

    /// A copy open in an editor is not brought up to date under it — what that
    /// editor holds would then be saved over it, from the older mine. Mine
    /// gets a copy of its own.
    @Test func aCopyOpenInAnEditorIsNotWrittenUnderIt() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)
        await editor.flush()
        let first = try #require(try copies(of: note).first)

        let reader = EditorModel()
        await reader.open(Note(title: first.deletingPathExtension().lastPathComponent, fileURL: first,
                               lastModified: Date(), fileSize: 0))
        editor.text = Self.mine + "More.\n"
        await editor.flush()
        #expect(try copies(of: note).count == 2, "the copy open in an editor was written under it")
        #expect(try onDisk(first) == Self.mine)
        withExtendedLifetime(reader) {}
    }

    /// A tab whose mine could be kept nowhere stays open, banner and all:
    /// closing it dropped mine.
    @Test func aTabThatCannotKeepMineStaysOpen() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let tabs = EditorTabs()
        let editor = await tabs.editor(for: note)
        try await conflict(in: editor, on: note)

        // A folder that takes no new file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let active = await tabs.close(note.id)
        #expect(tabs.editors.contains { $0 === editor }, "a tab whose mine was kept nowhere was closed")
        #expect(active == note.id)
        #expect(editor.saveError != nil && editor.hasConflict)
    }

    /// **A tab whose save was refused stays open with what it holds.** A
    /// save is refused while the note's folder has gone ("Your changes are
    /// kept here until it's back") or the note never loaded, and the buffer
    /// keeps the edit. Closing the tab flushed — refused again — and removed
    /// it whatever the flush did, so the changes the banner promised to keep
    /// went with it (tabs.md §2.5, item 6; implemented.md §51.36).
    @Test func aTabWhoseSaveWasRefusedStaysOpen() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let tabs = EditorTabs()
        let editor = await tabs.editor(for: note)
        editor.saveBlockedReason = { _ in "The folder holding this note isn't there." }
        editor.typed(Self.mine + "Typed while it was gone.\n")

        let active = await tabs.close(note.id)
        #expect(tabs.editors.contains { $0 === editor }, "a tab holding a refused save was closed")
        #expect(active == note.id)
        #expect(editor.text.hasSuffix("Typed while it was gone.\n") && editor.saveError != nil)
    }

    /// The control: typed back to what the file says, there is nothing to
    /// keep, and the tab closes — or a tab that once held a refused save
    /// could never be closed.
    @Test func aTabTypedBackToTheFileCloses() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let tabs = EditorTabs()
        let editor = await tabs.editor(for: note)
        editor.saveBlockedReason = { _ in "The folder holding this note isn't there." }
        let original = editor.text
        editor.typed(original + "Typed, then taken out again.\n")
        editor.typed(original)

        await tabs.close(note.id)
        #expect(!tabs.editors.contains { $0 === editor }, "a tab with nothing to keep stayed open")
    }

    /// Closing a tab with the banner up is letting go of it.
    @Test func closingATabWithAConflictKeepsMine() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let tabs = EditorTabs()
        let editor = await tabs.editor(for: note)
        try await conflict(in: editor, on: note)

        await tabs.close(note.id)
        #expect(try onDisk(note.fileURL) == Self.theirs, "closing the tab wrote mine over theirs")
        #expect(try copies(of: note).map { try onDisk($0) } == [Self.mine], "mine went with the tab")
    }

    /// So is an editor opening another note: its buffer is about to be
    /// replaced.
    @Test func openingAnotherNoteKeepsMine() async throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = try makeNote(in: dir)
        let other = try makeNote(named: "Other", "# Other\n", in: dir)
        let editor = EditorModel()
        await editor.open(note)
        try await conflict(in: editor, on: note)

        await editor.open(other)
        #expect(try onDisk(note.fileURL) == Self.theirs, "opening another note wrote mine over theirs")
        #expect(try copies(of: note).map { try onDisk($0) } == [Self.mine], "mine was dropped with the buffer")
        #expect(!editor.hasConflict && editor.text == "# Other\n")
    }
}

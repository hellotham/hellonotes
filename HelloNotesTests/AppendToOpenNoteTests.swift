//
//  AppendToOpenNoteTests.swift
//  HelloNotesTests
//
//  What Quick Capture, dictation and the daily-note intent append reaches the
//  note — the one on screen, when it is on screen.
//
//  `Collection.append` read the file, wrote the file and told the index
//  (`noteDidSave`) — which marks the write as the app's own, so the watcher
//  says nothing to anyone. Today's note is the note most likely to be open:
//  its tab kept the text it had, and with typing not yet saved its next save
//  met a file it had not written and asked the person to choose between what
//  they typed and what they captured. And the write was a read and then a
//  plain write, so a save landing between the two was written over (found by
//  the vault-I/O review of implemented.md §51.44; §51.45).
//
//  It is made in the editor that holds the note, as a linked mention is
//  (`MentionLinkTests`), and otherwise over the text it was appended to and
//  no other, with the open editors told.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct AppendToOpenNoteTests {

    private static let daily = "# 2026-10-12\n\n"

    /// A folder holding today's note, scanned.
    private func collectionWithADailyNote() throws -> (Collection, Note, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppendToOpenNote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileIO.write(Self.daily, to: root.appendingPathComponent("2026-10-12.md"))
        let collection = Collection(rootURL: root)
        collection.scan()
        return (collection, try #require(collection.note(titled: "2026-10-12")), root)
    }

    private func editor(on note: Note, in collection: Collection) async -> EditorModel {
        let editor = EditorModel()
        EditorWiring { _ in collection }.wire(editor)
        await editor.open(note)
        return editor
    }

    /// The defect: the note is open with typing not yet saved, and something
    /// is captured into it. Both are the note's, and nobody is asked to choose.
    @Test func aCaptureIntoANoteWithUnsavedTypingKeepsBoth() async throws {
        let (collection, note, root) = try collectionWithADailyNote()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = await editor(on: note, in: collection)
        editor.typed(Self.daily + "Typed, not yet saved.\n")

        #expect(await collection.append("- captured\n", to: note))

        let both = Self.daily + "Typed, not yet saved.\n- captured\n"
        #expect(editor.text == both, "the capture was not made to what is on screen")
        await editor.save()
        #expect(!editor.hasConflict, "the person was asked to choose between what they typed and what they captured")
        #expect(try FileIO.readString(at: note.fileURL) == both)
    }

    /// Open, with nothing unsaved: the tab shows the capture, and it is saved.
    @Test func aCaptureIntoAnOpenNoteIsOnScreenAndOnDisk() async throws {
        let (collection, note, root) = try collectionWithADailyNote()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = await editor(on: note, in: collection)

        #expect(await collection.append("- captured\n", to: note))

        #expect(editor.text == Self.daily + "- captured\n")
        // Written by the time it answers — "Added" is said on that answer.
        #expect(try FileIO.readString(at: note.fileURL) == Self.daily + "- captured\n",
                "the append answered before the capture was in the file")
        #expect(!editor.isDirty && !editor.hasConflict)
    }

    /// The control, and the path that must not change: no editor holds the
    /// note, so the file is written and the index told.
    @Test func aCaptureIntoANoteNoEditorHoldsGoesToTheFile() async throws {
        let (collection, note, root) = try collectionWithADailyNote()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await collection.append("- first\n", to: note))
        #expect(await collection.append("- second\n", to: note))

        #expect(try FileIO.readString(at: note.fileURL) == Self.daily + "- first\n- second\n")
    }

    /// A line is started for the capture when the note does not end one, and
    /// not when it does or when the note is empty.
    @Test func aCaptureStartsOnALineOfItsOwn() {
        #expect(Collection.appending("- new\n", to: "Ends without one") == "Ends without one\n- new\n")
        #expect(Collection.appending("- new\n", to: "Ends with one\n") == "Ends with one\n- new\n")
        #expect(Collection.appending("- new\n", to: "") == "- new\n")
    }

    /// A note that cannot be read is not an empty one to append to: nothing
    /// is written, and the append says it was not made.
    @Test func aNoteThatCannotBeReadIsNotAppendedTo() async throws {
        let (collection, note, root) = try collectionWithADailyNote()
        defer { try? FileManager.default.removeItem(at: root) }
        // Bytes no text encoding the app reads will take.
        try Data([0xFF, 0xFE, 0xFD, 0x00, 0xD8, 0x00]).write(to: note.fileURL)
        try #require((try? FileIO.readString(at: note.fileURL)) == nil,
                     "the file was read after all, so this shows nothing about one that cannot be")

        #expect(await collection.append("- captured\n", to: note) == false)
        #expect(try Data(contentsOf: note.fileURL) == Data([0xFF, 0xFE, 0xFD, 0x00, 0xD8, 0x00]),
                "something was written over a note that could not be read")
        #expect(collection.lastError != nil, "nothing said the capture was not made")
    }
}

/// New Collection ▸ Git Repository… — the folder it makes is a collection, and
/// its README is written as a collection's files are. It was a plain
/// `Data.write`, the one uncoordinated write the vault-I/O review found
/// (implemented.md §51.45).
@MainActor
struct NewRepositoryTests {

    @Test func aNewRepositoryHasItsReadmeCommitted() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let made = try #require(await GitService().createRepository(named: "Field Notes", in: parent))

        #expect(made.lastPathComponent == "Field Notes")
        #expect(try FileIO.readString(at: made.appendingPathComponent("README.md")) == "# Field Notes\n")
        let git = GitService()
        git.rootURL = made
        await git.refreshStatus()
        #expect(git.status.isRepository && git.status.isClean, "the README was not in the first commit")
        #expect(await git.history(for: made.appendingPathComponent("README.md")).map(\.summary) == ["Initial commit"])
    }

    /// **A file of that name is not deleted.** `createDirectory` failed on it
    /// and the cleanup for a failed create removed whatever had the name: the
    /// person's file (found by the vault-I/O review, implemented.md §51.45).
    @Test func aFileOfThatNameIsLeftAlone() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("Ledger")
        try Data("mine".utf8).write(to: file)

        let git = GitService()
        #expect(await git.createRepository(named: "Ledger", in: parent) == nil)
        #expect((try? Data(contentsOf: file)) == Data("mine".utf8), "a file named as the new repository was deleted")
        #expect(git.lastError?.contains("isn't a folder") == true, "\(git.lastError ?? "nothing said")")
    }

    /// An empty folder of that name becomes the repository — it is the
    /// person's folder, and stays theirs.
    @Test func anEmptyFolderOfThatNameBecomesTheRepository() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewRepository-\(UUID().uuidString)", isDirectory: true)
        let empty = parent.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let made = try #require(await GitService().createRepository(named: "Empty", in: parent))
        #expect(try FileIO.readString(at: made.appendingPathComponent("README.md")) == "# Empty\n")
    }

    /// A folder that already holds something is not made into a repository
    /// over it — the check the README's `create` relies on.
    @Test func aFolderThatIsNotEmptyIsLeftAlone() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewRepository-\(UUID().uuidString)", isDirectory: true)
        let taken = parent.appendingPathComponent("Taken", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileIO.write("# Mine\n", to: taken.appendingPathComponent("README.md"))

        let git = GitService()
        #expect(await git.createRepository(named: "Taken", in: parent) == nil)
        #expect(try FileIO.readString(at: taken.appendingPathComponent("README.md")) == "# Mine\n")
        #expect(git.lastError?.contains("isn't empty") == true)
    }
}


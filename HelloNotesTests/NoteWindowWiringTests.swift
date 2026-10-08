//
//  NoteWindowWiringTests.swift
//  HelloNotesTests
//
//  A note window (`NoteWindowView`) held a bare `EditorModel` and opened its
//  note itself, where a tab's editor is wired to the collection its note lives
//  in (docs/implemented.md §51.19). Each gap is shown here through the window's
//  own path (`NoteWindowView.load`), beside the same thing through a tab — the
//  control, wired as the shell wires tabs, which passed before the window was
//  wired and passes now.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct NoteWindowWiringTests {

    /// Two notes on a provider, mirrored into a cache with room for both, and
    /// the mirror's collection walked — so both are placeholders, and listed
    /// as online-only.
    private func mirroredCollection() async throws
        -> (collection: Collection, store: MockRemoteStore, cache: URL, notes: [Note]) {
        let store = MockRemoteStore(preAuthenticated: true)
        for name in ["First", "Second"] {
            try await store.write(Data("# \(name)\n\nA line of the note.\n".utf8), to: "/\(name).md")
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hn-window-\(UUID().uuidString)")
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()
        let collection = Collection(rootURL: cache)
        collection.remote = mirror
        await collection.scanOffMain()
        let notes = try ["First", "Second"].map { try #require(collection.note(titled: $0)) }
        return (collection, store, cache, notes)
    }

    /// A note opened as a note window opens it.
    private func inANoteWindow(_ note: Note, of collection: Collection) async -> EditorModel {
        let editor = EditorModel()
        await NoteWindowView.load(note, into: editor, wiring: EditorWiring { _ in collection })
        return editor
    }

    /// The same note opened in a tab, wired as the shell wires its tabs — and
    /// the tabs, which a window keeps for as long as its editors, and so must
    /// the test: a tab's editor asks its tabs for the wiring when it uses it.
    private func inATab(_ note: Note, of collection: Collection) async -> (EditorTabs, EditorModel) {
        let tabs = EditorTabs()
        tabs.wiring = EditorWiring { _ in collection }
        return (tabs, await tabs.editor(for: note))
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func onTheProvider(_ path: String, in store: MockRemoteStore) async -> String? {
        guard let data = try? await store.read(path: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - A cloud note still a placeholder

    /// The note's bytes are fetched before the editor reads the file. A note
    /// window read the placeholder, and opened the note empty — and what was
    /// typed there was written over it.
    @Test func aCloudNoteOpensInANoteWindowWithItsText() async throws {
        let (collection, _, cache, notes) = try await mirroredCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        #expect(try Data(contentsOf: notes[0].fileURL).isEmpty, "the note is not a placeholder, so this tests nothing")

        let editor = await inANoteWindow(notes[0], of: collection)
        #expect(editor.text.hasPrefix("# First"), "a note window opened a placeholder as the note: \(editor.text.debugDescription)")
    }

    @Test func aCloudNoteOpensInATabWithItsText() async throws {
        let (collection, _, cache, notes) = try await mirroredCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let (tabs, editor) = await inATab(notes[0], of: collection)
        defer { withExtendedLifetime(tabs) {} }
        #expect(editor.text.hasPrefix("# First"))
    }

    // MARK: - A download that fails

    /// A cloud note whose bytes cannot be fetched — the provider cannot be
    /// reached — is not opened as an empty note. It stays unloaded, so nothing
    /// typed is written over its placeholder (which the next download would
    /// write over in turn), and Try Again fetches it once the provider answers.
    /// It opened as an empty note, in a tab and a note window alike, and Try
    /// Again read the file without fetching anything.
    private func fetchFails(open: (Note, Collection) async -> EditorModel) async throws {
        let (collection, store, cache, notes) = try await mirroredCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        store.signOut()

        let editor = await open(notes[0], collection)
        #expect(editor.loadFailure != nil, "a note that could not be fetched opened as an empty note")
        #expect(collection.note(titled: "First")?.isOnlineOnly == true,
                "a note that could not be fetched lost its cloud badge, as if it had arrived")
        editor.text = "Typed into what looked like the note."
        await editor.save()
        #expect(try Data(contentsOf: notes[0].fileURL).isEmpty, "what was typed was written over the placeholder")

        try await store.authenticate()
        await editor.open(notes[0])   // the banner's Try Again
        #expect(editor.loadFailure == nil, "Try Again did not open the note")
        // What was typed is kept, set against the note that was fetched
        // (`EditorModel.open`): Try Again used to load the note over it.
        #expect(editor.hasConflict && editor.text == "Typed into what looked like the note.")
        await editor.resolveConflictReloading()
        #expect(editor.text.hasPrefix("# First"), "Try Again did not fetch the note: \(editor.text.debugDescription)")
    }

    @Test func aCloudNoteThatCannotBeFetchedIsNotOpenedEmptyInANoteWindow() async throws {
        try await fetchFails { note, collection in await inANoteWindow(note, of: collection) }
    }

    @Test func aCloudNoteThatCannotBeFetchedIsNotOpenedEmptyInATab() async throws {
        let tabs = EditorTabs()
        defer { withExtendedLifetime(tabs) {} }
        try await fetchFails { note, collection in
            tabs.wiring = EditorWiring { _ in collection }
            return await tabs.editor(for: note)
        }
    }

    // MARK: - A save

    /// A save reaches the note's collection: it is indexed, and on a cloud
    /// collection uploaded — and, first of all, registered as the app's own
    /// write (`Collection.noteDidSave`), so the watcher does not report it to
    /// the tabs as a change made elsewhere. A note window's saves reached
    /// nothing but the file.
    @Test func aSaveInANoteWindowReachesItsCollection() async throws {
        let (collection, store, cache, notes) = try await mirroredCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let editor = await inANoteWindow(notes[0], of: collection)
        editor.text = "---\naliases: [Nick]\n---\n" + editor.text
        await editor.save()

        #expect(await eventually { await onTheProvider("/First.md", in: store)?.hasPrefix("---\naliases: [Nick]") == true },
                "the save never reached the provider")
        await collection.savesIndexed()
        #expect(collection.linkGraph.resolve("Nick") == notes[0].fileURL, "the save was never indexed")
    }

    @Test func aSaveInATabReachesItsCollection() async throws {
        let (collection, store, cache, notes) = try await mirroredCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let (tabs, editor) = await inATab(notes[0], of: collection)
        defer { withExtendedLifetime(tabs) {} }
        editor.text = "---\naliases: [Nick]\n---\n" + editor.text
        await editor.save()

        #expect(await eventually { await onTheProvider("/First.md", in: store)?.hasPrefix("---\naliases: [Nick]") == true })
        await collection.savesIndexed()
        #expect(collection.linkGraph.resolve("Nick") == notes[0].fileURL)
    }

    // MARK: - A folder that has gone

    /// A local collection, walked, with one note in it.
    private func localCollection() async throws -> (collection: Collection, note: Note, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hn-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("On disk.".utf8).write(to: root.appendingPathComponent("Note.md"))
        let collection = Collection(rootURL: root)
        await collection.scanOffMain()
        return (collection, try #require(collection.note(titled: "Note")), root)
    }

    /// A save into a collection whose folder has gone is refused, and the edit
    /// kept in the buffer until the folder is back. A note window wrote it.
    @Test func aNoteWindowDoesNotWriteIntoAFolderThatHasGone() async throws {
        let (collection, note, root) = try await localCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = await inANoteWindow(note, of: collection)
        collection.markUnavailable(.unmounted)
        editor.text = "Typed while the folder was gone."
        await editor.save()

        #expect(editor.saveError != nil, "the save was not refused")
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "On disk.",
                "a note window wrote into a folder its collection had lost")
        #expect(editor.isDirty, "the edit was not kept")
    }

    @Test func aTabDoesNotWriteIntoAFolderThatHasGone() async throws {
        let (collection, note, root) = try await localCollection()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tabs, editor) = await inATab(note, of: collection)
        defer { withExtendedLifetime(tabs) {} }
        collection.markUnavailable(.unmounted)
        editor.text = "Typed while the folder was gone."
        await editor.save()

        #expect(editor.saveError != nil)
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8) == "On disk.")
    }

    // MARK: - What the editor asks its collection

    /// The editor asks the note's collection whether a file is a stand-in
    /// before it takes a change on disk as the note's text, and tells it when
    /// a note has arrived, so the note's row loses its cloud badge. Asked here
    /// of the other note, still a placeholder and listed as online-only.
    @Test func aNoteWindowAsksItsCollectionAboutItsNotes() async throws {
        let (collection, _, cache, notes) = try await mirroredCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let editor = await inANoteWindow(notes[0], of: collection)
        let other = notes[1].fileURL
        #expect(collection.note(titled: "Second")?.isOnlineOnly == true, "the other note is not online-only, so this tests nothing")

        #expect(editor.isPlaceholder?(other) == true, "a note window cannot tell a placeholder from a note")
        editor.onBecameAvailable?(other)
        #expect(collection.note(titled: "Second")?.isOnlineOnly == false,
                "a note that arrived in a note window kept its cloud badge")
    }

    @Test func aTabAsksItsCollectionAboutItsNotes() async throws {
        let (collection, _, cache, notes) = try await mirroredCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let (tabs, editor) = await inATab(notes[0], of: collection)
        defer { withExtendedLifetime(tabs) {} }
        let other = notes[1].fileURL

        #expect(editor.isPlaceholder?(other) == true)
        editor.onBecameAvailable?(other)
        #expect(collection.note(titled: "Second")?.isOnlineOnly == false)
    }
}

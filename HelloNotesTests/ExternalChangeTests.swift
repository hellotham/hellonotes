//
//  ExternalChangeTests.swift
//  HelloNotesTests
//
//  When a note changes on disk — another app, a sync, a `git pull` — every
//  editor open on it is told: a clean one loads the change, one with unsaved
//  edits raises the conflict banner. It was one closure on the app-wide
//  `Library`, which each main window's `.task` set, so only the main window
//  opened last was told, and a note window's editor never was — it found out
//  only when its next save found the file changed (docs/implemented.md §51.24).
//
//  Each window subscribes as its view does (`ContentView.observeExternalChanges`,
//  `NoteWindowView.observeExternalChanges`), and the collection's own watcher
//  reports the change to the library, as `Library.open` has it do. The library
//  opens nothing itself: that would write the test's folder into the app's
//  collection list, in the app's real preferences.
//

import Foundation
import SwiftUI
import Testing
@testable import HelloNotes

@MainActor
struct ExternalChangeTests {

    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Three notes in a folder, and a collection on it whose watcher tells
    /// `library` when something changes there — as `Library.open` has it.
    private func folder(toldTo library: Library) async throws -> (Collection, URL, [Note]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalChange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = ["First", "Second", "Third"]
        for name in names {
            try Data("# \(name)\n\nAs it was.\n".utf8).write(to: root.appendingPathComponent("\(name).md"))
        }
        let collection = Collection(rootURL: root)
        await collection.activate(onExternalChange: { [weak library] in library?.collectionChangedOnDisk() })
        let notes = try names.map { try #require(collection.note(titled: $0)) }
        return (collection, root, notes)
    }

    /// A main window with `note` open in a tab — its tabs wired as the shell
    /// wires them.
    private func mainWindow(_ note: Note, of collection: Collection) async -> (EditorTabs, EditorModel) {
        let tabs = EditorTabs()
        tabs.wiring = EditorWiring { _ in collection }
        return (tabs, await tabs.editor(for: note))
    }

    /// A note window with `note` open, loaded as the window loads it.
    private func noteWindow(_ note: Note, of collection: Collection) async -> EditorModel {
        let editor = EditorModel()
        await NoteWindowView.load(note, into: editor, wiring: EditorWiring { _ in collection })
        return editor
    }

    /// Written by something other than this app.
    private func changeElsewhere(_ note: Note) throws {
        try Data("# \(note.title)\n\nChanged elsewhere.\n".utf8).write(to: note.fileURL)
    }

    /// Two main windows, each with a note open in a tab, and a note window
    /// with a third: a change on disk to all three reaches every one of them,
    /// and each main window's selection is revalidated. The control is the
    /// main window opened last — the one the single closure named, told before
    /// the fix as after.
    @Test func aChangeOnDiskReachesEveryWindowsEditor() async throws {
        let library = Library()
        let (collection, root, notes) = try await folder(toldTo: library)
        defer { collection.deactivate(); try? FileManager.default.removeItem(at: root) }
        // Each window's selection, read when it is revalidated.
        let (first, inFirst) = await mainWindow(notes[0], of: collection)
        var firstRevalidated = 0
        let firstSelection = Binding<Note.ID?>(get: { firstRevalidated += 1; return notes[0].id }, set: { _ in })
        ContentView.observeExternalChanges(of: library, tabs: first, selection: firstSelection)
        let (second, inSecond) = await mainWindow(notes[1], of: collection)
        var secondRevalidated = 0
        let secondSelection = Binding<Note.ID?>(get: { secondRevalidated += 1; return notes[1].id }, set: { _ in })
        ContentView.observeExternalChanges(of: library, tabs: second, selection: secondSelection)
        let inNoteWindow = await noteWindow(notes[2], of: collection)
        NoteWindowView.observeExternalChanges(of: library, editor: inNoteWindow)
        defer { withExtendedLifetime((first, second)) {} }

        for note in notes { try changeElsewhere(note) }

        #expect(await eventually { inSecond.text.contains("Changed elsewhere") },
                "the main window opened last was not told")
        #expect(secondRevalidated > 0)
        #expect(await eventually { inFirst.text.contains("Changed elsewhere") },
                "a main window opened earlier was never told")
        #expect(firstRevalidated > 0, "a main window opened earlier never had its selection revalidated")
        #expect(await eventually { inNoteWindow.text.contains("Changed elsewhere") },
                "a note window's editor was never told")
    }

    /// The same, with something typed and not saved in each: every one raises
    /// its conflict when the change arrives — a note window's did only when
    /// its next save found the file changed — and nothing is written over the
    /// change. The control is again the main window opened last.
    @Test func aChangeOnDiskRaisesEveryWindowsConflictWhenItArrives() async throws {
        let library = Library()
        let (collection, root, notes) = try await folder(toldTo: library)
        defer { collection.deactivate(); try? FileManager.default.removeItem(at: root) }
        let (first, inFirst) = await mainWindow(notes[0], of: collection)
        ContentView.observeExternalChanges(of: library, tabs: first, selection: .constant(nil))
        let (second, inSecond) = await mainWindow(notes[1], of: collection)
        ContentView.observeExternalChanges(of: library, tabs: second, selection: .constant(nil))
        let inNoteWindow = await noteWindow(notes[2], of: collection)
        NoteWindowView.observeExternalChanges(of: library, editor: inNoteWindow)
        defer { withExtendedLifetime((first, second)) {} }
        for (editor, note) in zip([inFirst, inSecond, inNoteWindow], notes) {
            editor.text = "# \(note.title)\n\nTyped here, not saved.\n"
        }

        for note in notes { try changeElsewhere(note) }

        #expect(await eventually { inSecond.hasConflict }, "the main window opened last raised no conflict")
        #expect(await eventually { inFirst.hasConflict }, "a main window opened earlier raised no conflict")
        #expect(await eventually { inNoteWindow.hasConflict }, "a note window raised no conflict when the change arrived")
        for note in notes {
            #expect(try String(contentsOf: note.fileURL, encoding: .utf8).contains("Changed elsewhere"),
                    "what was typed in “\(note.title)” was written over the change")
        }
    }

    /// A window that has closed stops being told — its view says so as it
    /// goes — and the ones still open go on being told.
    @Test func aWindowThatHasClosedIsNotTold() async throws {
        let library = Library()
        let (collection, root, notes) = try await folder(toldTo: library)
        defer { collection.deactivate(); try? FileManager.default.removeItem(at: root) }
        let (closed, inClosed) = await mainWindow(notes[0], of: collection)
        ContentView.observeExternalChanges(of: library, tabs: closed, selection: .constant(nil))
        let (open, inOpen) = await mainWindow(notes[1], of: collection)
        ContentView.observeExternalChanges(of: library, tabs: open, selection: .constant(nil))
        let inClosedNoteWindow = await noteWindow(notes[2], of: collection)
        NoteWindowView.observeExternalChanges(of: library, editor: inClosedNoteWindow)
        // Appeared — its catch-up done — and then gone.
        try await Task.sleep(for: .milliseconds(100))
        library.stopObservingExternalChanges(of: closed)
        library.stopObservingExternalChanges(of: inClosedNoteWindow)
        defer { withExtendedLifetime((closed, open)) {} }

        for note in notes { try changeElsewhere(note) }

        #expect(await eventually { inOpen.text.contains("Changed elsewhere") }, "the window still open was not told")
        // Time for the closed ones' reconcile to have landed, had they been told.
        try await Task.sleep(for: .milliseconds(500))
        #expect(inClosed.text.contains("As it was"), "a main window that had closed was told")
        #expect(inClosedNoteWindow.text.contains("As it was"), "a note window that had closed was told")
    }

    /// A window that went and came back — its view appearing again — catches
    /// up on the change made while it was gone, which nothing told it about.
    @Test func aWindowThatComesBackCatchesUp() async throws {
        let library = Library()
        let (collection, root, notes) = try await folder(toldTo: library)
        defer { collection.deactivate(); try? FileManager.default.removeItem(at: root) }
        let (tabs, inTab) = await mainWindow(notes[0], of: collection)
        ContentView.observeExternalChanges(of: library, tabs: tabs, selection: .constant(nil))
        let inNoteWindow = await noteWindow(notes[1], of: collection)
        NoteWindowView.observeExternalChanges(of: library, editor: inNoteWindow)
        // Appeared — its catch-up done — and then gone.
        try await Task.sleep(for: .milliseconds(100))
        library.stopObservingExternalChanges(of: tabs)
        library.stopObservingExternalChanges(of: inNoteWindow)
        defer { withExtendedLifetime(tabs) {} }

        try changeElsewhere(notes[0])
        try changeElsewhere(notes[1])
        // Long enough for the watcher to have told everyone listening.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(inTab.text.contains("As it was") && inNoteWindow.text.contains("As it was"),
                "a window that had gone was told")

        ContentView.observeExternalChanges(of: library, tabs: tabs, selection: .constant(nil))
        NoteWindowView.observeExternalChanges(of: library, editor: inNoteWindow)
        #expect(await eventually { inTab.text.contains("Changed elsewhere") },
                "a main window that came back missed the change made while it was gone")
        #expect(await eventually { inNoteWindow.text.contains("Changed elsewhere") },
                "a note window that came back missed the change made while it was gone")
    }

    /// The library holds a window's editors weakly, and the window's own
    /// handler holds nothing of the window — a selection binding like the
    /// shell's, to one value of its state — so one that goes without saying so
    /// is not kept alive by being told about changes, and telling the windows
    /// afterwards passes it by. The shell's handler took a value built from
    /// the whole view, whose state holds the tabs.
    /// An editor goes when its last owner does — in a test as in a window.
    /// Registering itself in the table of every editor (`everyEditor`, a weak
    /// `NSHashTable`) retained and autoreleased it, so it lived on until the
    /// run loop's pool drained: in some orders of the suite, past the check
    /// below and the one after it (implemented.md §51.36).
    @Test func anEditorGoesWithItsLastOwner() {
        weak var gone: EditorModel?
        do { let editor = EditorModel(); gone = editor }
        #expect(gone == nil, "an editor outlived its last owner")
    }

    @Test func theLibraryKeepsNoWindowAlive() {
        final class State { var selection: Note.ID? }
        let library = Library()
        weak var goneTabs: EditorTabs?
        weak var goneEditor: EditorModel?
        do {
            let tabs = EditorTabs()
            let state = State()
            ContentView.observeExternalChanges(of: library, tabs: tabs,
                                               selection: Binding(get: { state.selection }, set: { state.selection = $0 }))
            let editor = EditorModel()
            NoteWindowView.observeExternalChanges(of: library, editor: editor)
            goneTabs = tabs
            goneEditor = editor
        }
        #expect(goneTabs == nil, "the library kept a main window's tabs alive")
        #expect(goneEditor == nil, "the library kept a note window's editor alive")
        library.collectionChangedOnDisk()
    }
}

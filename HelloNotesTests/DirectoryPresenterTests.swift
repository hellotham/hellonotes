//
//  DirectoryPresenterTests.swift
//  HelloNotesTests
//
//  The iOS folder watcher, driven on the Mac: `DirectoryPresenter` is only ever
//  run on iOS, and a callback it never implemented — a subitem moved under file
//  coordination — went unnoticed for its whole life. A rename made in the
//  Files app, or by Obsidian sharing the folder, was never heard: the sidebar
//  kept the old name until an unrelated change walked the folder.
//

import Foundation
import Synchronization
import Testing
@testable import HelloNotes

@Suite
struct DirectoryPresenterTests {

    /// What a presenter has reported, read from the test after the presenter's
    /// own queue has written it.
    private final class Heard: Sendable {
        private let events = Mutex<[DirectoryEvent]>([])
        func add(_ event: DirectoryEvent) { events.withLock { $0.append(event) } }
        var all: [DirectoryEvent] { events.withLock { $0 } }
        /// Every path any `.itemsChanged` carried.
        var paths: [String] {
            all.flatMap { event -> [String] in
                if case .itemsChanged(let paths) = event { return paths }
                return []
            }
        }
    }

    /// The collection's handling of each event a presenter heard, for a test
    /// to wait on.
    private final class Handed: Sendable {
        private let tasks = Mutex<[Task<Void, Never>]>([])
        func add(_ task: Task<Void, Never>) { tasks.withLock { $0.append(task) } }
        var count: Int { tasks.withLock { $0.count } }
        func handled() async { for task in tasks.withLock({ $0 }) { await task.value } }
    }

    /// `folder` spelled `/private/var/…` where it is under `/var` — a folder
    /// with two names, spelled as an iPhone's document picker hands one over
    /// (implemented.md §51.64). In the sandboxed host's container a folder has
    /// one name, and this is that name.
    private static func asAnIPhoneSpellsIt(_ folder: URL) -> URL {
        folder.path.hasPrefix("/var/") ? URL(filePath: "/private" + folder.path, directoryHint: .isDirectory) : folder
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "presenter-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Wait for `condition`, in looks (`Waits.Patience`), never seconds.
    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        var patience = Waits.Patience(timeout)
        while patience.lasts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// **A note renamed under file coordination is heard as one move, by
    /// both names, at once.** The move is the app's own `FileIO.move` — what
    /// the Files app and any coordinated mover do — made with a coordinator
    /// of its own, as another app's would be. Control: without
    /// `presentedSubitem(at:didMoveTo:)` the coordinator falls back to its
    /// other callbacks, which arrive about a second later, one name each.
    @Test func aSubitemMovedUnderCoordinationIsHeardByBothNames() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appending(path: "Untitled.md")
        let new = folder.appending(path: "Titled.md")
        try Data("# Untitled\n".utf8).write(to: old)

        let heard = Heard()
        let presenter = DirectoryPresenter(root: folder) { heard.add($0) }
        presenter.start()
        defer { presenter.stop() }

        try await offMain { try FileIO.move(from: old, to: new) }
        func oneEventWithBoth() -> Bool {
            heard.all.contains { event in
                guard case .itemsChanged(let paths) = event else { return false }
                let standardized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                return standardized.contains(old.standardizedFileURL.path)
                    && standardized.contains(new.standardizedFileURL.path)
            }
        }
        let both = await eventually(.seconds(3)) { oneEventWithBoth() }
        #expect(both, "the move was not reported as one event by both names; heard: \(heard.all)")
    }

    /// And a change written under coordination is still heard, as it was.
    @Test func aSubitemChangedUnderCoordinationIsHeard() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Note.md")
        try Data("# Note\n".utf8).write(to: note)

        let heard = Heard()
        let presenter = DirectoryPresenter(root: folder) { heard.add($0) }
        presenter.start()
        defer { presenter.stop() }

        try await offMain { try FileIO.write(Data("# Note\n\nchanged\n".utf8), to: note) }
        let changed = await eventually {
            heard.paths.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == note.standardizedFileURL.path }
                || heard.all.contains(.unspecifiedChange)
        }
        #expect(changed, "the write was not reported: \(heard.all)")
    }

    /// **A collection's own changes are not news to it.** On iOS a collection
    /// hears its folder through this presenter, and a coordinated change
    /// reaches it *while* it is made — a delete before the collection has
    /// forgotten the note. A note deleted, a folder made and a folder deleted
    /// each read as someone else's change, and asked for a walk of the vault
    /// on top of the collection's own; each is registered as the collection's
    /// before it is made now (implemented.md §51.64). The events reach the
    /// collection as the app hands them (`Collection.startObserving`).
    @Test @MainActor func aCollectionsOwnChangesAreNotNewsToIt() async throws {
        let made = try makeFolder()
        defer { try? FileManager.default.removeItem(at: made) }
        // Spelled as an iPhone hands a folder over, `/private/var/…`, where the
        // host's temporary folder is under `/var` — CI's unsandboxed one. A
        // path spelled so is known by another name once it exists, and the
        // collection walked the vault for a folder it had just made.
        let folder = Self.asAnIPhoneSpellsIt(made)
        try Data("# Going\n".utf8).write(to: folder.appending(path: "Going.md"))
        try Data("# Staying\n".utf8).write(to: folder.appending(path: "Staying.md"))
        let old = folder.appending(path: "Old", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        let note = try #require(collection.notes.first { $0.title == "Going" })

        let heard = Heard()
        let handed = Handed()
        let presenter = DirectoryPresenter(root: folder) { event in
            heard.add(event)
            Task { @MainActor in handed.add(collection.receive(event) {}) }
        }
        presenter.start()
        defer {
            presenter.stop()
            collection.deactivate()
        }
        let asked = collection.walksAskedFor

        await collection.deleteNote(note)
        let new = try #require(await collection.createFolder(named: "New"))
        await collection.deleteFolder(at: old)
        // A rename — what naming a new note is — a move and a copy, each told
        // to the presenter while it is made, or just after.
        let staying = try #require(collection.notes.first { $0.title == "Staying" })
        let renamed = try #require(await collection.renameNote(staying, to: "Stayed"))
        _ = try #require(await collection.moveItem(at: renamed.fileURL, into: new))
        let inNew = try #require(collection.notes.first { $0.title == "Stayed" })
        _ = try #require(await collection.duplicateNote(inNew))
        for ending in ["/Going.md", "/New", "/Old", "/Staying.md", "/New/Stayed.md", "/New/Stayed copy.md"] {
            let named = await eventually { heard.paths.contains { $0.hasSuffix(ending) } }
            #expect(named, "the presenter never heard of …\(ending), so this tests nothing: \(heard.all)")
        }
        // Every event heard handed to the collection, and handled.
        #expect(await eventually { handed.count == heard.all.count })
        await handed.handled()
        #expect(collection.walksAskedFor == asked,
                "the collection's own changes asked for \(collection.walksAskedFor - asked) walks: \(heard.all)")
    }

    /// **A path is known by its place in the collection, whichever name its
    /// folder goes by — and whether or not it is there.** `/etc` and
    /// `/private/etc` are one folder, as an iPhone's `/var` and `/private/var`
    /// are, and `hosts` is there where the other name is not. The key was the
    /// canonical path, which drops `/private` only from a path that exists, so
    /// a folder registered before it was made was looked up afterwards under
    /// the other name, and walked as news (implemented.md §51.64).
    @Test @MainActor func aPathIsKnownByItsPlaceWhicheverNameItsFolderHas() {
        let collection = Collection(rootURL: URL(filePath: "/private/etc", directoryHint: .isDirectory))
        let missing = "no-such-\(UUID().uuidString)"
        let keys = ["/etc/hosts", "/private/etc/hosts", "/etc/\(missing)", "/private/etc/\(missing)", "/etc"]
            .map { collection.selfWriteKey($0) }
        #expect(keys == ["hosts", "hosts", missing, missing, ""], "keys: \(keys)")
        #expect(collection.selfWriteKey("/private/var/elsewhere/x.md") == nil)
    }

    /// **What is not the collection's is not news to it**: a change under a
    /// hidden name — a commit's `.git/index`, Obsidian's workspace — which no
    /// walk lists, or outside the collection altogether. Only the last name
    /// was asked whether it was hidden, so every commit walked the vault. A
    /// change made elsewhere to a note still is news.
    @Test @MainActor func whatIsNotTheCollectionsIsNotNewsToIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        defer { collection.deactivate() }
        let asked = collection.walksAskedFor

        let notOurs = [folder.appending(path: ".git/index").path,
                       folder.appending(path: ".git/refs/heads/main").path,
                       folder.appending(path: ".obsidian/workspace.json").path,
                       FileManager.default.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString).md").path]
        await collection.receive(.itemsChanged(notOurs)) {}.value
        #expect(collection.walksAskedFor == asked,
                "a change that is not the collection's asked for \(collection.walksAskedFor - asked) walks")

        // Made, not merely named: a path that is not there and that the
        // collection never showed changes nothing it shows (§51.69).
        let madeElsewhere = folder.appending(path: "Made elsewhere.md")
        try Data("# Made elsewhere\n".utf8).write(to: madeElsewhere)
        await collection.receive(.itemsChanged([madeElsewhere.path])) {}.value
        #expect(collection.walksAskedFor == asked + 1, "a change made elsewhere to a note was not news")
    }

    /// **The collection's own save, heard long after, is not news.** iOS tells
    /// a suspended app nothing and hands it everything on its return, the save
    /// it made on its way out among it — the note and the atomic save's own
    /// temporary file, measured in the simulator — long past the time window
    /// that recognises the collection's own writes. Each was taken for someone
    /// else's change, and the vault was walked at every return to the app
    /// (implemented.md §51.69). What the save left is looked at instead, and a
    /// note the collection shows untouched is not news either. A change made
    /// elsewhere since, a new file and a shown note gone still are — each on a
    /// collection of its own, so no walk one of them asks for can answer for
    /// the next.
    @Test @MainActor func theCollectionsOwnSaveHeardLongAfterIsNotNews() async throws {
        #expect(try await walksAsked { folder in
            [folder.appending(path: "Note.md").path,
             folder.appending(path: "Note.md").path + ".sb-1f2f778f-xENn8V",
             folder.appending(path: "Shown.md").path]
        } == 0, "the collection's own save, heard late, asked for a walk")

        #expect(try await walksAsked { folder in
            let note = folder.appending(path: "Note.md")
            try Data("# Note\n\nChanged on another device, at more length.\n".utf8).write(to: note)
            return [note.path]
        } == 1, "a change made elsewhere after the save was not news")

        #expect(try await walksAsked { folder in
            let new = folder.appending(path: "New.md")
            try Data("# New\n".utf8).write(to: new)
            return [new.path]
        } == 1, "a new file was not news")

        #expect(try await walksAsked { folder in
            let gone = folder.appending(path: "Shown.md")
            try FileManager.default.removeItem(at: gone)
            return [gone.path]
        } == 1, "a shown note gone was not news")
    }

    /// **A deletion heard before it is made is news when the collection shows
    /// what is going.** iOS asks a presenter to accommodate a delete before
    /// making it, and a look at the disk then found the note still there and
    /// unchanged — a note deleted on another device stayed listed
    /// (implemented.md §51.72). Something the collection does not show — its
    /// own delete, heard late — is not. The control: the same path, heard as
    /// a change, is no news while the file is untouched.
    @Test @MainActor func aDeletionHeardBeforeItIsMadeIsNewsWhenShown() async throws {
        #expect(try await walksAsked(as: DirectoryEvent.itemsDeleting) { folder in
            [folder.appending(path: "Shown.md").path]
        } == 1, "a shown note about to be deleted was not news")
        #expect(try await walksAsked(as: DirectoryEvent.itemsDeleting) { folder in
            [folder.appending(path: "Never shown.md").path]
        } == 0, "the delete of something never shown was news")
        #expect(try await walksAsked { folder in
            [folder.appending(path: "Shown.md").path]
        } == 0, "the control: an untouched shown note heard as a change was news")
    }

    /// **A note the collection saved, gone from the picture and put back as it
    /// was, is news.** Its saved size and date explained it only while the
    /// picture still showed it: recovered from Recently Deleted, or put back
    /// from the Trash, it was never listed again (implemented.md §51.72).
    @Test @MainActor func aSavedNoteBackFromAwayIsNews() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Note.md")
        try Data("# Note\n".utf8).write(to: note)
        try Data("# Shown\n".utf8).write(to: folder.appending(path: "Shown.md"))
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        defer { collection.deactivate() }

        let saved = "# Note\n\nTyped before it went to the Trash.\n"
        try Data(saved.utf8).write(to: note)
        collection.noteDidSave(note, text: saved)
        // Events take turns: one heard now is handled after the save's look.
        await collection.receive(.itemsChanged([])) {}.value

        // Gone, and gone from the picture; then put back with its date and size.
        let away = FileManager.default.temporaryDirectory.appending(path: "away-\(UUID().uuidString).md")
        try FileManager.default.moveItem(at: note, to: away)
        await collection.scanOffMain()
        try #require(!collection.notes.contains { $0.title == "Note" }, "the walk still shows the note gone")
        try FileManager.default.moveItem(at: away, to: note)
        collection.forgetRecentSelfWrites()

        let asked = collection.walksAskedFor
        await collection.receive(.itemsChanged([note.path])) {}.value
        #expect(collection.walksAskedFor == asked + 1, "the saved note, put back with its saved bytes, was not news")
    }

    /// **A late look waits for no look at the folder.** The check on late
    /// news asked about each changed file on the collection's own lane, where
    /// the folder is looked at, in the event's turn — so one held up the other
    /// (implemented.md §51.72). With that lane held, the look still answers:
    /// an untouched note is no news.
    @Test(.timeLimit(.minutes(1))) @MainActor func aLateLookWaitsForNoLookAtTheFolder() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Note.md")
        try Data("# Note\n".utf8).write(to: note)
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        defer { collection.deactivate() }

        let letGo = DispatchSemaphore(value: 0)
        defer { letGo.signal() }
        await hold(collection.rootCalls.lane(for: collection.rootURL), until: letGo)

        collection.forgetRecentSelfWrites()
        let asked = collection.walksAskedFor
        await collection.receive(.itemsChanged([note.path])) {}.value
        #expect(collection.walksAskedFor == asked, "an untouched note, looked at beside a held folder, was news")
    }

    /// **A file its provider does not answer about holds up no turn.** The
    /// check asks the provider about each changed file — its size, its date,
    /// whether it is downloaded — and waited for the answer however long it
    /// took: one note the provider never answered about held that turn and
    /// every one after it, an unmount, Try Again (implemented.md §51.72). The
    /// note's lane is held here, and the turn ends anyway — no answer is news,
    /// and the folder is walked — and so does the turn after it, while the
    /// lane is still held.
    @Test(.timeLimit(.minutes(1))) @MainActor func aFileItsProviderDoesNotAnswerAboutHoldsUpNoTurn() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Note.md")
        try Data("# Note\n".utf8).write(to: note)
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        defer { collection.deactivate() }

        // Lanes of the test's own: a lane held here holds no other test's look.
        let calls = FileIO.ProviderCalls(isHere: FileIO.ProviderCalls.live.isHere,
                                         askFor: FileIO.ProviderCalls.live.askFor,
                                         lanes: FileIO.ProviderCalls.makeLanes("hn-test.late-news"))
        collection.newsCalls = calls
        let letGo = DispatchSemaphore(value: 0)
        defer { letGo.signal() }
        await hold(calls.lane(for: URL(filePath: note.path, directoryHint: .notDirectory)), until: letGo)

        collection.forgetRecentSelfWrites()
        let asked = collection.walksAskedFor
        await collection.receive(.itemsChanged([note.path])) {}.value
        #expect(collection.walksAskedFor == asked + 1, "a file whose provider did not answer was not taken for news")
        await collection.receive(.rootChanged) {}.value
        #expect(collection.state == .ready, "the turn after it did not look at the folder")
    }

    /// **A change heard while a walk is coming is that walk's to read.** It
    /// lists the folder after the change. In a burst of news — a return to
    /// the app, a pull made on another device — every event after the first
    /// was looked at all the same, each against the whole picture on the main
    /// actor, and asked for a walk of its own (implemented.md §51.72). The
    /// control is the first event, which is looked at and found news.
    @Test @MainActor func aChangeHeardWhileAWalkIsComingIsThatWalksToRead() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "First.md"), second = folder.appending(path: "Second.md")
        try Data("# First\n".utf8).write(to: first)
        try Data("# Second\n".utf8).write(to: second)
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        defer { collection.deactivate() }
        // Coming for the whole test, whatever the machine's load.
        collection.reconcileDelay = .seconds(60)

        try Data("# First\n\nChanged on another device.\n".utf8).write(to: first)
        try Data("# Second\n\nChanged on another device.\n".utf8).write(to: second)
        collection.forgetRecentSelfWrites()
        let asked = collection.walksAskedFor
        await collection.receive(.itemsChanged([first.path])) {}.value
        #expect(collection.walksAskedFor == asked + 1, "the control: a change made elsewhere was not news")
        await collection.receive(.itemsChanged([second.path])) {}.value
        #expect(collection.walksAskedFor == asked + 1, "a change heard while a walk was coming asked for another")
    }

    /// Hold `lane` until `letGo` is signalled — a provider not answering about
    /// whatever falls on it — and return once the hold has begun.
    @MainActor private func hold(_ lane: DispatchQueue, until letGo: DispatchSemaphore) async {
        await withCheckedContinuation { (holding: CheckedContinuation<Void, Never>) in
            lane.async { holding.resume(); letGo.wait() }
        }
    }

    /// The walks a collection asks for when told of the paths `change` names,
    /// after it has saved a note and the time window has passed — a
    /// collection of its own, in a folder of its own.
    @MainActor private func walksAsked(as event: ([String]) -> DirectoryEvent = DirectoryEvent.itemsChanged,
                                       after change: (URL) throws -> [String]) async throws -> Int {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Note.md")
        try Data("# Note\n".utf8).write(to: note)
        try Data("# Shown\n".utf8).write(to: folder.appending(path: "Shown.md"))
        let collection = Collection(rootURL: folder)
        await collection.scanOffMain()
        defer { collection.deactivate() }
        try #require(collection.notes.count == 2)

        // Saved as the editor saves: written, then told to the collection.
        let saved = "# Note\n\nTyped before the app went home.\n"
        try Data(saved.utf8).write(to: note)
        collection.noteDidSave(note, text: saved)
        // The app is suspended, and the window that knows its writes by time
        // passes before it is back.
        collection.forgetRecentSelfWrites()
        let asked = collection.walksAskedFor
        let paths = try change(folder)
        await collection.receive(event(paths)) {}.value
        return collection.walksAskedFor - asked
    }
}

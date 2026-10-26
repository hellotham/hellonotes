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

        await collection.receive(.itemsChanged([folder.appending(path: "Made elsewhere.md").path])) {}.value
        #expect(collection.walksAskedFor == asked + 1, "a change made elsewhere to a note was not news")
    }
}

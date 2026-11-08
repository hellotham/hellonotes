//
//  PlacesAfterAMoveTests.swift
//  HelloNotesTests
//
//  What names a place by its path outlives a move of the app's container
//  (implemented.md §51.71). Open Recent told collections apart by path and
//  listed the sample collection once an install — twenty-one times on the
//  simulator; a window's last note and collection were not reopened after a
//  move, its open folders all closed, and the sidebar went to the Library
//  place. The container's earlier names are the test's own here; the app
//  learns them at launch (`ContainerMoves.learn`, §51.70).
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct PlacesAfterAMoveTests {

    /// The container as it was called, and as it is called after the move.
    nonisolated static let before = "/private/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540"
    nonisolated static let after = "/var/mobile/Containers/Data/Application/2CE3E666-44F0-43B9-AC5A-1416158DD683"
    nonisolated static let beforeOneSpelling = "/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540"

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PlacesAfterAMove-\(UUID().uuidString)", isDirectory: true)
    }

    private static func entry(_ id: String, _ name: String, bookmark: Data = Data(),
                              opened: Date = .distantPast) -> RecentsStore.Entry {
        RecentsStore.Entry(id: id, name: name, isObsidian: false, lastOpened: opened, bookmark: bookmark)
    }

    // MARK: - Names

    /// **A path kept under an earlier name of the container is today's
    /// path**, in the spelling it was kept in. Outside the container, in
    /// today's, and in a folder whose name only begins with the earlier
    /// one's, a path is as it was kept — and with no earlier names nothing
    /// moves.
    @Test func aPathKeptUnderAnEarlierNameIsTodaysPath() {
        let earlier = [Self.before]
        #expect(ContainerPath.todaysPath(of: Self.before + "/Documents/Notes/A.md", home: Self.after,
                                         earlierHomes: earlier)
                == "/private" + Self.after + "/Documents/Notes/A.md")
        #expect(ContainerPath.todaysPath(of: Self.beforeOneSpelling + "/Documents/Notes", home: Self.after,
                                         earlierHomes: earlier)
                == Self.after + "/Documents/Notes")
        #expect(ContainerPath.todaysPath(of: "/Users/someone/Notes", home: Self.after, earlierHomes: earlier)
                == "/Users/someone/Notes")
        #expect(ContainerPath.todaysPath(of: Self.after + "/Documents/Notes", home: Self.after, earlierHomes: earlier)
                == Self.after + "/Documents/Notes")
        #expect(ContainerPath.todaysPath(of: Self.before + "-other/Notes", home: Self.after, earlierHomes: earlier)
                == Self.before + "-other/Notes")
        #expect(ContainerPath.todaysPath(of: Self.before + "/Documents/Notes", home: Self.after, earlierHomes: [])
                == Self.before + "/Documents/Notes")
    }

    /// **Only a container named by a UUID is taken for one that moved.** The
    /// Mac's (`…/Data`) never moves, and an unsandboxed home is no container:
    /// without the rule a folder moved from `/Users/Shared` into one taught
    /// "the container was `/Users/Shared`". The control: two UUID-named
    /// containers, side by side, are learnt.
    @Test func onlyAContainerNamedByAUUIDIsLearnt() {
        #expect(ContainerPath.earlierHome(of: "/Users/Shared/Notes", now: "/Users/someone/Notes",
                                          home: "/Users/someone") == nil)
        let mac = "/Users/someone/Library/Containers/com.hellotham.HelloNotes"
        #expect(ContainerPath.earlierHome(of: mac + "/Other/Documents/Notes", now: mac + "/Data/Documents/Notes",
                                          home: mac + "/Data") == nil)
        #expect(ContainerPath.earlierHome(of: Self.before + "/Documents/Notes", now: Self.after + "/Documents/Notes",
                                          home: Self.after) == Self.beforeOneSpelling)
    }

    /// **A window's last note is found where it is now** — by place, kept
    /// under an earlier name or spelt the other way. The control: a note of
    /// the same name elsewhere is not it, and a note that is gone is none.
    @Test func aWindowsLastNoteIsFoundWhereItIsNow() {
        let notes = ["/Users/someone/Work/Plan.md", Self.after + "/Documents/Notes/Plan.md",
                     Self.after + "/Documents/Notes/Budget.md"]
        #expect(ContainerPath.index(of: Self.before + "/Documents/Notes/Plan.md", in: notes, home: Self.after,
                                    earlierHomes: [Self.before]) == 1)
        #expect(ContainerPath.index(of: "/private" + Self.after + "/Documents/Notes/Budget.md", in: notes,
                                    home: Self.after, earlierHomes: []) == 2)
        #expect(ContainerPath.index(of: Self.before + "/Documents/Notes/Gone.md", in: notes, home: Self.after,
                                    earlierHomes: [Self.before]) == nil)
    }

    /// **A window's open folders are named where they are now**, in the
    /// spelling they were kept in; a folder outside the container is as it
    /// was, and with no earlier names the list is as kept.
    @Test func aWindowsOpenFoldersAreNamedWhereTheyAreNow() {
        let kept = [Self.before + "/Documents/Notes/Projects", "/Users/someone/Work/Drafts"].joined(separator: "\n")
        let now = ExpandedFolders.inTodaysContainer(kept, home: Self.after, earlierHomes: [Self.before])
        #expect(Set(now.split(separator: "\n").map(String.init))
                == ["/private" + Self.after + "/Documents/Notes/Projects", "/Users/someone/Work/Drafts"])
        #expect(ExpandedFolders.inTodaysContainer(kept, home: Self.after, earlierHomes: []) == kept)
    }

    /// **The sidebar keeps the collection it stood in through a move.**
    /// Stored by its path under the container's earlier name, the collection
    /// was taken for closed and the window put on the Library place. The
    /// controls: a collection that has closed still sends the rail to the
    /// focus, and the Library place, chosen, stays.
    @Test func theSidebarKeepsItsCollectionThroughAMove() {
        let open = [Self.after + "/Documents/Notes", "/Users/someone/Work"]
        let stored = Self.beforeOneSpelling + "/Documents/Notes"
        #expect(RailPlaceStorage.keeping(stored, open: open, focused: nil, earlierHomes: [Self.before],
                                         home: Self.after) == open[0])
        #expect(RailPlaceStorage.respelled(stored, open: open, earlierHomes: [Self.before], home: Self.after)
                == open[0])
        #expect(RailPlaceStorage.keeping(Self.before + "/Documents/Gone", open: open, focused: open[1],
                                         earlierHomes: [Self.before], home: Self.after) == open[1])
        #expect(RailPlaceStorage.keeping(RailPlaceStorage.library, open: open, focused: open[0],
                                         earlierHomes: [Self.before], home: Self.after) == RailPlaceStorage.library)
    }

    /// **A setting kept per collection is found after a move** — the notes it
    /// pinned, whether it shows files that are not notes. Keyed by the
    /// collection's absolute path, both were lost at every move of the app's
    /// container (implemented.md §51.72). What was kept under the earlier name
    /// is moved to the stable one, and never over a value already there.
    @Test(.scratchDefaults) func aCollectionsSettingsAreFoundAfterAMove() {
        let defaults = ScratchDefaults.suite()
        let names = ContainerNames(home: Self.after, earlier: [Self.before])
        let root = Self.after + "/Documents/Notes"
        defaults.set(["Plan.md", "Projects/Budget.md"], forKey: "bookmarks:" + Self.beforeOneSpelling + "/Documents/Notes")
        let key = ContainerMoves.adoptKey("bookmarks:", for: root, in: defaults, names: names)
        #expect(key == "bookmarks:~/Documents/Notes")
        #expect(defaults.stringArray(forKey: key) == ["Plan.md", "Projects/Budget.md"], "the pins kept before the move were lost")
        #expect(defaults.object(forKey: "bookmarks:" + Self.beforeOneSpelling + "/Documents/Notes") == nil)

        defaults.set(false, forKey: "showsNonNoteFiles:" + Self.notesKeptToday)
        defaults.set(true, forKey: "showsNonNoteFiles:~/Documents/Notes")
        let shows = ContainerMoves.adoptKey("showsNonNoteFiles:", for: root, in: defaults, names: names)
        #expect(defaults.object(forKey: shows) as? Bool == true, "a value under the stable name was moved over")
        #expect(Collection.showFilesKey(root) == ContainerMoves.key("showsNonNoteFiles:", for: root))
    }

    nonisolated static let notesKeptToday = after + "/Documents/Notes"

    // MARK: - Open Recent

    /// **A collection opened again after a move is one entry, not two** — the
    /// entry kept under the container's earlier name is the same collection.
    /// The control: a folder of the same name elsewhere keeps its own entry.
    @Test(.scratchDefaults) func aCollectionOpenedAfterAMoveIsOneEntry() async throws {
        let defaults = ScratchDefaults.suite()
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let today = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let earlierHome = root.appendingPathComponent(UUID().uuidString, isDirectory: true).path
        let notes = today.appendingPathComponent("Documents/Notes", isDirectory: true)
        let elsewhere = root.appendingPathComponent("Elsewhere/Notes", isDirectory: true)
        for folder in [notes, elsewhere] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defaults.set([earlierHome], forKey: ContainerMoves.earlierHomesKey)
        defaults.set(try JSONEncoder().encode([Self.entry(earlierHome + "/Documents/Notes", "Notes"),
                                               Self.entry(elsewhere.path, "Notes")]),
                     forKey: RecentsStore.key)

        let recents = RecentsStore(defaults: defaults, home: today.path)
        await recents.record(notes)
        #expect(recents.entries.count == 2, "the entry kept under the container's earlier name stayed beside the new one")
        #expect(recents.entries.first.map { ContainerPath.oneSpelling($0.id) }
                == ContainerPath.oneSpelling(notes.standardizedFileURL.path))
        #expect(recents.entries.contains { $0.id == elsewhere.path })
    }

    /// **A window that removes an entry keeps what another recorded.** Each
    /// window has a store of its own, and one removing from its own copy of
    /// the list wrote over what another had just recorded (implemented.md
    /// §51.72). The control is the second window's own entry, kept as it
    /// recorded it.
    @Test(.scratchDefaults) func removingAnEntryKeepsWhatAnotherWindowRecorded() async throws {
        let defaults = ScratchDefaults.suite()
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("One", isDirectory: true)
        let two = root.appendingPathComponent("Two", isDirectory: true)
        for folder in [one, two] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        let firstWindow = RecentsStore(defaults: defaults), secondWindow = RecentsStore(defaults: defaults)
        await firstWindow.record(one)
        await secondWindow.record(two)
        try #require(secondWindow.entries.map(\.name) == ["Two", "One"])
        let entry = try #require(firstWindow.entries.first { $0.name == "One" })
        firstWindow.remove(entry)
        #expect(RecentsStore(defaults: defaults).entries.map(\.name) == ["Two"],
                "removing from one window's list dropped what the other had recorded")
    }

    /// **The entries earlier moves left for one folder are tidied into one**
    /// — found by their bookmarks, which follow a folder where a path does
    /// not; the most recent kept, named where the folder is now, and kept so.
    /// The controls: a folder of the same name elsewhere keeps its entry, and
    /// an entry whose name no other shares is not looked at.
    @Test(.scratchDefaults) func entriesLeftByEarlierMovesAreTidiedIntoOne() async throws {
        let defaults = ScratchDefaults.suite()
        let root = Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("Container/Documents/Notes", isDirectory: true)
        let other = root.appendingPathComponent("Other/Notes", isDirectory: true)
        for folder in [notes, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let bookmark = try #require(Bookmark.data(for: notes))
        let otherBookmark = try #require(Bookmark.data(for: other))
        // Three installs' worth of the one folder, as twenty-one left the sample on the simulator.
        let moved = (0..<3).map { index in
            Self.entry("/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Documents/Notes", "Notes",
                       bookmark: bookmark, opened: Date(timeIntervalSince1970: Double(10 - index)))
        }
        let kept = moved + [Self.entry(other.path, "Notes", bookmark: otherBookmark),
                            Self.entry("/Users/someone/Work", "Work")]
        defaults.set(try JSONEncoder().encode(kept), forKey: RecentsStore.key)

        let home = root.appendingPathComponent("Container", isDirectory: true).path
        let recents = RecentsStore(defaults: defaults, home: home)
        await recents.tidy()
        #expect(recents.entries.map(\.name) == ["Notes", "Notes", "Work"])
        #expect(recents.entries.first.map { ContainerPath.oneSpelling($0.id) }
                == ContainerPath.oneSpelling(notes.path))
        #expect(recents.entries.first?.lastOpened == moved[0].lastOpened, "the most recent was not the one kept")
        #expect(recents.entries.contains { ContainerPath.oneSpelling($0.id) == ContainerPath.oneSpelling(other.path) })
        #expect(recents.entries.last?.id == "/Users/someone/Work")
        #expect(RecentsStore(defaults: defaults, home: home).entries.count == 3, "the tidied list was not kept")
    }
}

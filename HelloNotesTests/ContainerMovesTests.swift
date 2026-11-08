//
//  ContainerMovesTests.swift
//  HelloNotesTests
//
//  What the app keeps for a collection outlives a move of the app's container
//  (`ContainerMoves`, implemented.md §51.70). The Assistant's conversation,
//  the links declined, a walk's resume point and the index cache were each
//  named from the collection's absolute path, and an iOS app's container is
//  a folder named by a UUID that moves — at every install on the simulator,
//  measured. Kept under the old name, each was found by nobody. And a cloud
//  collection's cache was looked for only where it had been kept, so the
//  collection itself was dropped.
//
//  "What 1.3.5 kept" is written by hand in each test, the way 1.3.5 named
//  it: the digest of the root's `standardizedFileURL.path` — the `/var`
//  spelling for a root that exists, as an iPhone's does.
//

import Foundation
import FoundationModels
import Testing
@testable import HelloNotes

@MainActor
struct ContainerMovesTests {

    /// The container as it was called, and as it is called after the move.
    nonisolated static let before = "/private/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540"
    nonisolated static let after = "/var/mobile/Containers/Data/Application/2CE3E666-44F0-43B9-AC5A-1416158DD683"
    nonisolated static let notes = after + "/Documents/Notes"
    nonisolated static let notesBefore = before + "/Documents/Notes"

    nonisolated static let moved = ContainerNames(home: after, earlier: [before])
    nonisolated static let stayed = ContainerNames(home: after)

    private static func scratch(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// The name 1.3.5 gave `path`'s store.
    private static func keptName(_ path: String) -> String {
        ContainerMoves.digest(ContainerPath.oneSpelling(path))
    }

    private static let conversation: [Transcript.Entry] = [
        .prompt(Transcript.Prompt(metadata: [:], segments: [.text(.init(content: "Where did I put the plan?"))])),
        .response(Transcript.Response(metadata: [:], segments: [.text(.init(content: "In Projects/Plan."))])),
    ]

    // MARK: - Names

    /// **A path inside the container was kept under its place in each
    /// container**, in both spellings; one outside it under itself. A folder
    /// whose name merely begins with the container's is outside it.
    @Test func aPathsFormerNamesAreItsPlaceUnderEachNameOfTheContainer() {
        let names = ContainerPath.formerNames(of: Self.notes, home: Self.after, earlierHomes: [Self.before])
        #expect(Set(names) == [
            "/var/mobile/Containers/Data/Application/2CE3E666-44F0-43B9-AC5A-1416158DD683/Documents/Notes",
            "/private/var/mobile/Containers/Data/Application/2CE3E666-44F0-43B9-AC5A-1416158DD683/Documents/Notes",
            "/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540/Documents/Notes",
            "/private/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540/Documents/Notes",
        ])
        #expect(names.count == 4)
        #expect(ContainerPath.formerNames(of: "/Users/someone/Notes", home: Self.after, earlierHomes: [Self.before])
                == ["/Users/someone/Notes"])
        #expect(Set(ContainerPath.formerNames(of: Self.after + "-other/Notes", home: Self.after,
                                              earlierHomes: [Self.before]))
                == [Self.after + "-other/Notes", "/private" + Self.after + "-other/Notes"])
    }

    /// **The container's earlier name is what a kept path had before the
    /// part of the folder's path inside today's container** — and only a
    /// sibling of today's container counts: a folder moved into the container
    /// from elsewhere is a folder that moved, not a container.
    @Test func theContainersEarlierNameIsWhatAKeptPathHadBeforeTheFolder() {
        #expect(ContainerPath.earlierHome(of: Self.notesBefore, now: Self.notes, home: Self.after)
                == "/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540")
        #expect(ContainerPath.earlierHome(of: Self.notesBefore + "/", now: "/private" + Self.notes,
                                          home: Self.after + "/")
                == "/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540")
        // Nothing moved, in either spelling.
        #expect(ContainerPath.earlierHome(of: "/private" + Self.notes, now: Self.notes, home: Self.after) == nil)
        // A folder moved in from a stick is not a container that moved.
        #expect(ContainerPath.earlierHome(of: "/Volumes/Stick/Documents/Notes", now: Self.notes,
                                          home: Self.after) == nil)
        // Another folder, and a folder outside the container.
        #expect(ContainerPath.earlierHome(of: Self.before + "/Documents/Work", now: Self.notes,
                                          home: Self.after) == nil)
        #expect(ContainerPath.earlierHome(of: "/Users/a/Notes", now: "/Users/b/Notes", home: Self.after) == nil)
    }

    /// **Learnt once, kept, and only so many** — and nothing is learnt when
    /// nothing moved.
    @Test(.scratchDefaults) func theContainersEarlierNamesAreRemembered() {
        let defaults = ScratchDefaults.suite()
        #expect(ContainerMoves.learn(from: Self.notesBefore, now: Self.notes, home: Self.after, in: defaults)
                == "/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540")
        ContainerMoves.learn(from: Self.before + "/Documents/Work", now: Self.after + "/Documents/Work",
                             home: Self.after, in: defaults)
        #expect(ContainerMoves.earlierHomes(in: defaults) == ["/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540"])
        #expect(ContainerMoves.learn(from: Self.notes, now: Self.notes, home: Self.after, in: defaults) == nil)

        let moves = (0..<(ContainerMoves.earlierHomesLimit + 2)).map { _ in UUID().uuidString }
        for move in moves {
            ContainerMoves.learn(from: "/var/mobile/Containers/Data/Application/\(move)/Documents/Notes",
                                 now: Self.notes, home: Self.after, in: defaults)
        }
        let kept = ContainerMoves.earlierHomes(in: defaults)
        #expect(kept.count == ContainerMoves.earlierHomesLimit)
        #expect(kept.last == "/var/mobile/Containers/Data/Application/\(moves.last ?? "")")
    }

    // MARK: - What is kept

    /// **The Assistant's conversation outlives the container's moving** —
    /// kept under the collection's absolute path in the container as it was
    /// called, and found under its name in today's; then found again with no
    /// earlier name known, as the next launch finds it. The controls: it was
    /// moved, not copied; and another collection has no conversation.
    @Test func aConversationKeptBeforeTheContainerMovedIsFoundAfterIt() throws {
        let base = Self.scratch("ChatMove")
        defer { try? FileManager.default.removeItem(at: base) }
        let kept = base.appending(path: "HelloNotes/chats/\(Self.keptName(Self.notesBefore))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try JSONEncoder().encode(Transcript(entries: Self.conversation))
            .write(to: kept.appending(path: "transcript.json"))

        let root = URL(filePath: Self.notes, directoryHint: .isDirectory)
        #expect(ChatSessionStore(collectionURL: root, baseDirectory: base, names: Self.moved).load().count == 2)
        #expect(!FileManager.default.fileExists(atPath: kept.path), "the conversation was copied, not moved")
        #expect(ChatSessionStore(collectionURL: root, baseDirectory: base, names: Self.stayed).load().count == 2)
        let work = URL(filePath: Self.after + "/Documents/Work", directoryHint: .isDirectory)
        #expect(ChatSessionStore(collectionURL: work, baseDirectory: base, names: Self.moved).load().isEmpty)
    }

    /// **And on a device whose container did not move** — kept under the
    /// absolute path in today's container, in either spelling, and found with
    /// no earlier name at all.
    @Test(arguments: [Self.notes, "/private" + Self.notes])
    func aConversationKeptInTheContainerAsItIsIsFound(keptUnder path: String) throws {
        let base = Self.scratch("ChatStay")
        defer { try? FileManager.default.removeItem(at: base) }
        let kept = base.appending(path: "HelloNotes/chats/\(ContainerMoves.digest(path))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try JSONEncoder().encode(Transcript(entries: Self.conversation))
            .write(to: kept.appending(path: "transcript.json"))

        let root = URL(filePath: Self.notes, directoryHint: .isDirectory)
        #expect(ChatSessionStore(collectionURL: root, baseDirectory: base, names: Self.stayed).load().count == 2)
    }

    /// **A conversation kept under the stable name is never moved over** —
    /// the one the person has now wins over one an older build left behind,
    /// which stays where it is.
    @Test func aConversationUnderTheStableNameIsNeverReplaced() throws {
        let base = Self.scratch("ChatBoth")
        defer { try? FileManager.default.removeItem(at: base) }
        let chats = base.appending(path: "HelloNotes/chats", directoryHint: .isDirectory)
        let kept = chats.appending(path: Self.keptName(Self.notesBefore), directoryHint: .isDirectory)
        let current = chats.appending(path: ContainerMoves.digest("~/Documents/Notes"), directoryHint: .isDirectory)
        for folder in [kept, current] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(Transcript(entries: Self.conversation))
            .write(to: kept.appending(path: "transcript.json"))

        let root = URL(filePath: Self.notes, directoryHint: .isDirectory)
        #expect(ChatSessionStore(collectionURL: root, baseDirectory: base, names: Self.moved).load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: kept.appending(path: "transcript.json").path))
    }

    /// **The links declined stay declined after the container moves.** The
    /// control: another collection's list is its own.
    @Test func linksDeclinedBeforeTheContainerMovedStayDeclined() throws {
        let folder = Self.scratch("Declined")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(["Plan→Budget"])
            .write(to: folder.appending(path: "\(Self.keptName(Self.notesBefore)).json"))

        let root = URL(filePath: Self.notes, directoryHint: .isDirectory)
        #expect(DeclinedLinkStore(collectionRoot: root, folder: folder, names: Self.moved).contains("Plan→Budget"))
        #expect(DeclinedLinkStore(collectionRoot: root, folder: folder, names: Self.stayed).contains("Plan→Budget"))
        let work = URL(filePath: Self.after + "/Documents/Work", directoryHint: .isDirectory)
        #expect(!DeclinedLinkStore(collectionRoot: work, folder: folder, names: Self.moved).contains("Plan→Budget"))
    }

    /// **A walk's resume point outlives the container's moving** — named, as
    /// 1.3.5 named every path, by the path itself, which is what a path outside
    /// the container is still named by.
    @Test func aWalksPlaceKeptBeforeTheContainerMovedIsFoundAfterIt() throws {
        let folder = Self.scratch("Checkpoints")
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkpoint = WalkCheckpoint(frontier: ["a", "a/b"], directoriesVisited: 7,
                                        itemsSeen: 42, previousTotalDirectories: 99)
        let oldID = ContainerPath.oneSpelling(Self.notesBefore)
        let kept = try #require(WalkCheckpointStore.fileURL(for: oldID, in: folder,
                                                            names: ContainerNames(home: "/elsewhere")))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: kept)

        let found = try #require(WalkCheckpointStore.fileURL(for: Self.notes, in: folder, names: Self.moved))
        #expect(found != kept)
        #expect(try JSONDecoder().decode(WalkCheckpoint.self, from: Data(contentsOf: found)) == checkpoint)
        #expect(!FileManager.default.fileExists(atPath: kept.path))
    }

    /// **The index cache is found after the container moves**, and a walk not
    /// made: the cache kept under the absolute path is moved to the name
    /// `cacheURL` gives, which the saves write.
    @Test func anIndexCacheKeptBeforeTheContainerMovedIsFoundAfterIt() throws {
        let folder = Self.scratch("IndexCache")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = folder.appending(path: "\(Self.keptName(Self.notesBefore)).json")
        try Data("{}".utf8).write(to: kept)

        let root = URL(filePath: Self.notes, directoryHint: .isDirectory)
        let found = CollectionIndexCache.keptCacheURL(for: root, in: folder, names: Self.moved)
        #expect(FileManager.default.fileExists(atPath: found.path))
        #expect(!FileManager.default.fileExists(atPath: kept.path))
        #expect(found.lastPathComponent
                == CollectionIndexCache.cacheURL(for: root, home: Self.after).lastPathComponent)
    }

    // MARK: - Cloud collections

    /// **A cloud collection's cache is looked for in today's container too**
    /// — the same provider and folder — when the list kept it in another
    /// container's Application Support. Looked for only where it was kept, it
    /// was not found, and the collection was dropped. In today's container,
    /// in either spelling, it is looked for there alone; a folder that is no
    /// cache, as it is.
    @Test func aCloudCollectionsCacheIsLookedForInTodaysContainer() {
        let base = URL(filePath: Self.after + "/Library/Application Support/RemoteMirror", directoryHint: .isDirectory)
        let kept = Self.before + "/Library/Application Support/RemoteMirror/onedrive/Notes"
        #expect(RemoteMirror.cacheRoots(kept: kept, base: base).map(\.path)
                == [kept, Self.after + "/Library/Application Support/RemoteMirror/onedrive/Notes"])
        #expect(RemoteMirror.cacheRoots(kept: "/private" + Self.after + "/Library/Application Support/RemoteMirror/onedrive/Notes",
                                        base: base).count == 1)
        #expect(RemoteMirror.cacheRoots(kept: "/Users/someone/Notes", base: base).map(\.path) == ["/Users/someone/Notes"])

        // And the cache found there names the container it was kept in.
        #expect(ContainerPath.earlierHome(of: kept, now: Self.after + "/Library/Application Support/RemoteMirror/onedrive/Notes",
                                          home: Self.after)
                == "/var/mobile/Containers/Data/Application/ADE7D338-15AD-4AE0-A7BD-640BDBCE9540")
    }
}

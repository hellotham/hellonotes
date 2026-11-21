//
//  CollectionLookupTests.swift
//  HelloNotesTests
//
//  Which collection a note is in — the question every command on a note asks
//  before it does anything. Rename, Move to Trash, Duplicate, Pin and a drop
//  on a folder each begin `guard let collection = library.collection(containing:)
//  else { return }`, and a `nil` there is a command that does nothing at all:
//  no alert, no change, the note still open.
//
//  That is what the person's iPad did, four builds running, to a note made in
//  a folder of an Obsidian vault in iCloud Drive (implemented.md §51.74): it
//  could be neither renamed nor deleted, and quitting changed nothing. The
//  lookup compared the note's `standardizedFileURL` with the collection's
//  `id`, and both are answers the disk gives. A folder outside the app on an
//  iPad cannot be seen until its security scope is opened, and `/private` is
//  dropped only from a path that can be seen: at launch the identity was
//  worked out before the scope was open, so the id kept `/private/var/…`;
//  every lookup came after, when the note's path had lost it. A vault picked
//  in the Files app had its scope open, so its id was `/var/…`, and then New
//  Note — which compares the selected note's folder with the ids — went to
//  the root instead: the other report.
//
//  No Mac folder of the app's has two names that way, so the tests stage the
//  shape with a root reached through a link — the id is the link's target,
//  every note is spelled through the link — and spell the iPad's paths by
//  hand where nothing needs the disk.
//

import Foundation
import SwiftUI
import Testing
@testable import HelloNotes

@Suite(.serialized) @MainActor
struct CollectionLookupTests {

    /// A vault reached through a link: `Linked` → `Real`, with a folder.
    private func makeLinkedVault() throws -> (link: URL, parent: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "hn-lookup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let real = parent.appending(path: "Real", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real.appending(path: "Folder", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
        try "# Top\n".write(to: real.appending(path: "Top.md"), atomically: true, encoding: .utf8)
        try "# Inside\n".write(to: real.appending(path: "Folder/Inside.md"), atomically: true, encoding: .utf8)
        let link = parent.appending(path: "Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (link, parent)
    }

    /// The window's selection, as a binding the shell's commands write.
    private final class Selection { var url: URL? }

    private func actions(_ library: Library, selection: Selection, scope: Collection) -> ShellActions {
        ShellActions(library: library, tabs: EditorTabs(),
                     selection: Binding(get: { selection.url }, set: { selection.url = $0 }),
                     scope: scope,
                     renameTarget: .constant(nil), renameText: .constant(""),
                     newFolderCollection: .constant(nil), newFolderParent: .constant(nil),
                     newFolderName: .constant(""), pendingFolderDelete: .constant(nil),
                     expandedFolders: .constant([]),
                     openNoteWindow: { _ in }, reviewLinks: {})
    }

    private func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        // Looks, not seconds (`Waits`).
        for _ in 0..<Waits.looks(in: limit, every: .milliseconds(10)) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// **A note made in a folder can be renamed and moved to the Trash** —
    /// through the commands the person uses, not the collection's own
    /// functions: the test §51.56 wrote for this report renamed through
    /// `Collection.renameNote` and passed, while the shell's command in front
    /// of it found no collection and did nothing. Here the id is the link's
    /// target and every note is spelled through the link, as on the iPad the
    /// id was one name of the folder and the notes the other.
    @Test(.scratchDefaults) func aNoteMadeInAFolderCanBeRenamedAndDeleted() async throws {
        let (link, parent) = try makeLinkedVault()
        defer { try? FileManager.default.removeItem(at: parent) }
        let library = Library(defaults: ScratchDefaults.suite())
        defer { library.collections.forEach { $0.deactivate() } }
        let collection = await library.open(url: link)
        #expect(await eventually { collection.notes.contains { $0.title == "Inside" } })
        #expect(!collection.id.contains("/Linked"), "the premise: the id is the folder's other name")

        // New Note from the note open in the folder, decided as the column
        // decides it — compared with the id, it went to the root.
        let inside = try #require(collection.notes.first { $0.title == "Inside" })
        let folderID = try #require(ShellActions.newNoteFolder(
            band: nil, bandShowing: false, selected: inside.fileURL,
            collections: library.collections.map { ($0.id, $0.rootSpellings) }),
            "New Note from a note in the folder would go to the root")
        #expect(folderID == collection.id + "/Folder")
        let made = try #require(await collection.createNote(in: URL(fileURLWithPath: folderID, isDirectory: true)))
        #expect(made.fileURL.path.contains("/Linked/Folder/"), "made as \(made.fileURL.path)")
        #expect(library.collection(containing: made.fileURL) === collection,
                "no collection found for \(made.fileURL.path) — every command on it does nothing")

        let selection = Selection()
        selection.url = made.id
        let shell = actions(library, selection: selection, scope: collection)

        shell.rename(made, to: "Titled")
        let titled = made.fileURL.deletingLastPathComponent().appending(path: "Titled.md")
        #expect(await eventually { FileManager.default.fileExists(atPath: titled.path) },
                "Rename did nothing: the note is still \(made.fileURL.lastPathComponent)")
        #expect(await eventually { !collection.notes.contains { $0.title == "Untitled" } })
        #expect(selection.url?.lastPathComponent == "Titled.md", "the renamed note is not the one shown")

        let renamed = try #require(collection.notes.first { $0.title == "Titled" })
        shell.delete(renamed)
        #expect(await eventually { !FileManager.default.fileExists(atPath: renamed.fileURL.path) },
                "Move to Trash did nothing: \(renamed.fileURL.lastPathComponent) is still there")
        #expect(await eventually { !collection.notes.contains { $0.title == "Titled" } },
                "the deleted note is still listed")
        #expect(selection.url == nil, "the deleted note is still open")
    }

    /// **New Note from a note at the top of the vault is made under the
    /// collection's own name.** The folder is named by the sidebar's name for
    /// the collection — its id, the folder's other name — and only a path
    /// *inside* one of the folder's names was put back under its own, never
    /// the folder itself: the note was made as `Real/Untitled.md` while the
    /// walk lists `Linked/Untitled.md`, one file with two identities.
    @Test(.scratchDefaults) func aNoteMadeAtTheTopFromTheSidebarsNameKeepsTheCollectionsOwn() async throws {
        let (link, parent) = try makeLinkedVault()
        defer { try? FileManager.default.removeItem(at: parent) }
        let library = Library(defaults: ScratchDefaults.suite())
        defer { library.collections.forEach { $0.deactivate() } }
        let collection = await library.open(url: link)
        #expect(await eventually { collection.notes.contains { $0.title == "Top" } })

        let top = try #require(collection.notes.first { $0.title == "Top" })
        let folderID = try #require(ShellActions.newNoteFolder(
            band: nil, bandShowing: false, selected: top.fileURL,
            collections: library.collections.map { ($0.id, $0.rootSpellings) }))
        #expect(folderID == collection.id)
        let made = try #require(await collection.createNote(in: URL(fileURLWithPath: folderID, isDirectory: true)))
        #expect(made.fileURL.deletingLastPathComponent().path == link.path, "made as \(made.fileURL.path)")
        await collection.scanOffMain()
        #expect(collection.notes.filter { $0.title == "Untitled" }.count == 1, "one note, two identities")
        #expect(collection.notes.first { $0.title == "Untitled" }?.fileURL == made.fileURL)
    }

    /// **A note deleted under its folder's other name leaves the list.** The
    /// collection took a deleted note out by its URL, so a note handed in
    /// spelled the other way was deleted from the disk and stayed listed.
    @Test func aNoteDeletedUnderItsFoldersOtherNameLeavesTheList() async throws {
        let (link, parent) = try makeLinkedVault()
        defer { try? FileManager.default.removeItem(at: parent) }
        let collection = Collection(rootURL: link)
        await collection.scanOffMain()
        let top = try #require(collection.notes.first { $0.title == "Top" })
        let otherName = URL(fileURLWithPath: collection.id, isDirectory: true).appending(path: "Top.md")
        #expect(otherName != top.fileURL, "the premise: two names for one note")

        await collection.deleteNote(Note(title: top.title, fileURL: otherName,
                                         lastModified: top.lastModified, fileSize: top.fileSize))
        #expect(!FileManager.default.fileExists(atPath: top.fileURL.path), "the note was not deleted")
        #expect(!collection.notes.contains { $0.title == "Top" }, "deleted, and still listed")
    }

    // MARK: - The iPad's own spellings, by hand

    /// An Obsidian vault in iCloud Drive, as an iPad names it: the folder is
    /// `/private/var/…` when it is handed over and `/var/…` once Foundation
    /// has looked at it.
    private let vault = "/var/mobile/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault"
    private var spellings: [String] { [vault + "/", "/private" + vault + "/"] }

    /// Found under either name of the folder — and a sibling whose name only
    /// begins the same is not inside it.
    @Test func aPlaceIsFoundUnderEitherNameOfTheFolder() {
        #expect(Collection.place(of: "/private" + vault + "/Folder/Untitled.md", in: spellings) == "Folder/Untitled.md")
        #expect(Collection.place(of: vault + "/Folder/Untitled.md", in: spellings) == "Folder/Untitled.md")
        #expect(Collection.place(of: "/private" + vault, in: spellings) == "")
        #expect(Collection.place(of: vault + " 2/Note.md", in: spellings) == nil)
        #expect(Collection.place(of: "/var/mobile/Elsewhere/Note.md", in: spellings) == nil)
    }

    /// **New Note goes into the folder of the note that is open**, named as
    /// the sidebar names it, whichever name the id and the note each have.
    @Test func newNoteGoesIntoTheOpenNotesFolderUnderEitherName() {
        for id in [vault, "/private" + vault] {
            let collections = [(id: id, spellings: spellings)]
            for spelled in [vault, "/private" + vault] {
                let selected = URL(filePath: spelled + "/Folder/Untitled.md")
                #expect(ShellActions.newNoteFolder(band: nil, bandShowing: false, selected: selected,
                                                   collections: collections) == id + "/Folder",
                        "id \(id), note \(selected.path)")
                #expect(ShellActions.newNoteFolder(band: nil, bandShowing: false,
                                                   selected: URL(filePath: spelled + "/Top.md"),
                                                   collections: collections) == id)
            }
            #expect(ShellActions.newNoteFolder(band: nil, bandShowing: false,
                                               selected: URL(filePath: vault + " 2/Note.md"),
                                               collections: collections) == nil,
                    "a note in no open collection: the root of the one in scope")
            #expect(ShellActions.newNoteFolder(band: id + "/Folder", bandShowing: true, selected: nil,
                                               collections: collections) == id + "/Folder")
        }
    }

    /// **A drop on a folder takes a note of the same collection under either
    /// name**, and still refuses one already there or from elsewhere.
    @Test func aDropOnAFolderTakesANoteUnderEitherName() {
        let folder = DropTarget(folderURL: URL(filePath: vault + "/Folder", directoryHint: .isDirectory),
                                collectionID: vault, rootSpellings: spellings)
        #expect(folder.accepts(URL(filePath: "/private" + vault + "/Top.md")),
                "a note of the same collection, under the folder's other name, was refused")
        #expect(!folder.accepts(URL(filePath: "/private" + vault + "/Folder/Untitled.md")), "already there")
        #expect(!folder.accepts(URL(filePath: "/private" + vault + " 2/Note.md")), "another collection")
        let top = DropTarget(folderURL: URL(filePath: "/private" + vault, directoryHint: .isDirectory),
                             collectionID: vault, rootSpellings: spellings)
        #expect(top.accepts(URL(filePath: vault + "/Folder/Untitled.md")))
        #expect(!top.accepts(URL(filePath: vault + "/Top.md")), "already there")
    }

    /// **A collection is called the same whether or not its folder can be
    /// seen** — as an iCloud folder on an iPad cannot be until its scope is
    /// open, which at launch it was not yet: the id kept `/private` then and
    /// lost it when the folder was picked, one vault with two names.
    @Test func aCollectionIsCalledTheSameWhetherOrNotItsFolderCanBeSeen() {
        // The premise, on a folder this Mac has under both names: seen, it is
        // called by the short one.
        #expect(Collection.Identity(of: URL(filePath: "/private/var/db", directoryHint: .isDirectory)).id == "/var/db")
        let unseen = "/private/var/hn-unseen-\(UUID().uuidString)/Vault"
        let identity = Collection.Identity(of: URL(filePath: unseen, directoryHint: .isDirectory))
        #expect(identity.id == String(unseen.dropFirst("/private".count)), "called \(identity.id) while it cannot be seen")
        #expect(identity.spellings.contains(identity.id + "/"), "the id is not one of its folder's spellings")
        #expect(identity.spellings.contains(unseen + "/"))
    }
}

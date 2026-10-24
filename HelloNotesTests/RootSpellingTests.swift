//
//  RootSpellingTests.swift
//  HelloNotesTests
//
//  `/var/x` and `/private/var/x` are one directory with two names, and the app
//  has to recognise both — because the system hands it both, in the same
//  breath. On a CI runner `FileManager.temporaryDirectory` reported a
//  collection's root as `/var/folders/…` while `contentsOfDirectory(at:)`
//  reported every file inside it as `/private/var/folders/…`.
//
//  When no prefix matches, `relativePath` returns the file's *absolute* path as
//  though it were relative. Everything downstream then fails quietly: the cache
//  stores a path that cannot be rebuilt into a URL, two pictures of the same
//  folder never compare equal, and a merge cannot tell a note inside an
//  unreadable subtree from one that has been deleted — so it keeps the deleted
//  one.
//
//  Pure string arithmetic on purpose. The first attempt at this test built real
//  symlinked directories and passed on the machine it was written on, which is
//  the failure mode it was meant to catch.
//

import Testing
import Foundation
@testable import HelloNotes

@Suite
struct RootSpellingTests {

    /// The exact pairing CI produced.
    @Test func aVarRootRecognisesPrivateVarFiles() {
        let root = URL(filePath: "/var/folders/df/abc/T/hn-vault")
        let file = URL(filePath: "/private/var/folders/df/abc/T/hn-vault/Note 0.md")
        #expect(CollectionIndexCache.relativePath(of: file, in: root) == "Note 0.md")
    }

    /// And the other way round, since either side can be the one Foundation
    /// hands back in the short form.
    @Test func aPrivateVarRootRecognisesVarFiles() {
        let root = URL(filePath: "/private/var/folders/df/abc/T/hn-vault")
        let file = URL(filePath: "/var/folders/df/abc/T/hn-vault/Sub/Note.md")
        #expect(CollectionIndexCache.relativePath(of: file, in: root) == "Sub/Note.md")
    }

    /// A path that genuinely is not inside the root stays absolute, so callers
    /// can still tell "not mine" from "at my root".
    @Test func somethingOutsideTheRootIsNotClaimed() {
        let root = URL(filePath: "/var/folders/df/abc/T/hn-vault")
        let file = URL(filePath: "/Users/someone/Elsewhere/Note.md")
        #expect(CollectionIndexCache.relativePath(of: file, in: root).hasPrefix("/"))
    }

    /// A sibling whose name merely starts the same must not be swallowed — the
    /// reason every prefix carries its separator.
    @Test func aSiblingWithASharedPrefixIsNotInsideTheRoot() {
        let root = URL(filePath: "/var/folders/df/abc/T/Notes")
        let file = URL(filePath: "/var/folders/df/abc/T/NotesArchive/Note.md")
        #expect(CollectionIndexCache.relativePath(of: file, in: root).hasPrefix("/"),
                "“NotesArchive” is not inside “Notes”")
    }

    /// Ordinary roots keep working, and gain a harmless extra candidate.
    @Test func anOrdinaryRootIsUnaffected() {
        let root = URL(filePath: "/Users/someone/Vault")
        let file = URL(filePath: "/Users/someone/Vault/Folder/Note.md")
        #expect(CollectionIndexCache.relativePath(of: file, in: root) == "Folder/Note.md")
    }
}

/// A collection whose *root* is a symlink.
///
/// `~/Notes` pointing into iCloud Drive is an ordinary setup, and it opened
/// completely empty: `contentsOfDirectory(at:)` refuses a symlink at the end of
/// the path with ENOTDIR, while `Collection.unavailability` — which uses the
/// `atPath:` variant, and does not — reported the folder as perfectly healthy.
/// So nothing was wrong, and nothing was there.
@Suite @MainActor
struct SymlinkedRootTests {

    private func makeLinkedVault(noteCount: Int = 3) throws -> (link: URL, parent: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "hn-symroot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let real = parent.appending(path: "Real", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real.appending(path: "Sub", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
        for i in 0..<noteCount {
            try "# Note \(i)\n".write(to: real.appending(path: "Note \(i).md"),
                                      atomically: true, encoding: .utf8)
        }
        try "# Nested\n".write(to: real.appending(path: "Sub/Nested.md"),
                               atomically: true, encoding: .utf8)
        let link = parent.appending(path: "Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (link, parent)
    }

    /// The premise, so a failure below is about the app and not about the
    /// filesystem: the URL enumerator really does refuse this.
    @Test func theEnumeratorRefusesASymlinkedDirectory() throws {
        let (link, parent) = try makeLinkedVault()
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: link.path)) != nil,
                "the path-based variant works, which is why nothing noticed")
        #expect((try? FileManager.default.contentsOfDirectory(
            at: link, includingPropertiesForKeys: nil)) == nil,
                "the URL-based variant is the one that refuses it")
    }

    @Test func aSymlinkedRootFindsItsNotes() async throws {
        let (link, parent) = try makeLinkedVault()
        defer { try? FileManager.default.removeItem(at: parent) }

        let collection = Collection(rootURL: link)
        await collection.scanOffMain()

        #expect(collection.notes.count == 4, """
            a collection reached through a symlink came up empty.
            state: \(collection.state)
            notes: \(collection.notes.map(\.fileURL.path).sorted())
            """)
        #expect(collection.notes.contains { $0.title == "Nested" },
                "subdirectories under a symlinked root have to be walked too")
    }

    /// **A note made in a folder keeps the collection's own spelling, and so
    /// stays one note.** The sidebar names a folder by the collection's
    /// canonical id (`Collection.id`), which is the folder's *other* name —
    /// where a link points, or on an iPhone, where every root is
    /// `/private/var/…`, the `/var/…` form — and the shell builds the folder
    /// URL from that id. Built so, a new note's URL was spelled the canonical
    /// way while every walked note is spelled the root's: one file, two
    /// identities. The next walk replaced the made note with its walked twin,
    /// and a rename then took out only the one it was handed — "Untitled"
    /// stayed in the sidebar beside the new name. The person's iPad, builds
    /// 33 and 34, which no Mac or simulator could show: neither has a root
    /// with two names.
    @Test func aNoteMadeInAFolderKeepsTheCollectionsOwnSpelling() async throws {
        let (link, parent) = try makeLinkedVault(noteCount: 1)
        defer { try? FileManager.default.removeItem(at: parent) }
        let collection = Collection(rootURL: link)
        await collection.scanOffMain()

        // The folder as the sidebar ids it, and as the shell then spells it.
        let folderID = collection.id + "/Sub"
        let folder = URL(fileURLWithPath: folderID, isDirectory: true)
        #expect(!folderID.contains("/Linked/"), "the premise: the id is the folder's other name")

        let made = try #require(await collection.createNote(title: "Untitled", in: folder))
        #expect(made.fileURL.path.contains("/Linked/Sub/"), "made as \(made.fileURL.path)")
        await collection.scanOffMain()
        let walked = collection.notes.filter { $0.title == "Untitled" }
        #expect(walked.count == 1)
        #expect(walked.first?.fileURL == made.fileURL,
                "the walk spelled it another way: \(walked.first?.fileURL.path ?? "none")")

        // The inline title's route: a rename handed the note as it was made.
        _ = try #require(await collection.renameNote(made, to: "Titled"))
        #expect(!FileManager.default.fileExists(atPath: made.fileURL.path))
        #expect(collection.notes.filter { $0.title == "Untitled" }.isEmpty, "the old name stayed listed")
        #expect(collection.notes.filter { $0.title == "Titled" }.count == 1)
        await collection.scanOffMain()
        #expect(collection.notes.filter { $0.title == "Untitled" }.isEmpty)
        #expect(collection.notes.filter { $0.title == "Titled" }.count == 1)

        // A move into the folder, whose destination the shell builds the same way.
        let top = try #require(collection.notes.first { $0.title == "Note 0" })
        let moved = try #require(await collection.moveItem(at: top.fileURL, into: folder))
        #expect(moved.path.contains("/Linked/Sub/"), "moved to \(moved.path)")
        #expect(collection.notes.filter { $0.title == "Note 0" }.count == 1)
        #expect(collection.notes.first { $0.title == "Note 0" }?.fileURL.path.contains("/Linked/Sub/") == true)
    }

    /// The notes keep the spelling the collection was opened with, so selection
    /// and the index cache still match them.
    @Test func notesKeepTheCollectionsOwnSpelling() async throws {
        let (link, parent) = try makeLinkedVault(noteCount: 1)
        defer { try? FileManager.default.removeItem(at: parent) }

        let collection = Collection(rootURL: link)
        await collection.scanOffMain()
        let note = try #require(collection.notes.first { $0.title == "Note 0" })
        #expect(note.fileURL.path.contains("/Linked/"),
                "got \(note.fileURL.path) — a resolved path here breaks selection and the cache")
        #expect(CollectionIndexCache.relativePath(of: note.fileURL, in: link) == "Note 0.md")
    }
}

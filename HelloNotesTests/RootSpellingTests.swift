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

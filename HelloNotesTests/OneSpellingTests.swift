//
//  OneSpellingTests.swift
//  HelloNotesTests
//
//  A collection calls every file in it by one name for its folder — its own.
//
//  `/var` is `/private/var`, and a listing of `/var/…` comes back as
//  `/private/var/…` without `resolvingSymlinksInPath` ever admitting to a
//  link. Both ways a collection lists its folder kept the listing's name, so
//  a collection rooted at `/var/…` held its scanned notes under one spelling
//  and the ones it made, moved or renamed under the other — and a note's
//  identity is its URL. A tab on a note that had not moved was closed when
//  another did; a note made again at a path was "not at the same path"; a
//  cloud note was not found in its own manifest (implemented.md §51.48).
//
//  An iPhone's containers are spelled both ways like this and the
//  simulator's are not, so nothing here could show it: the test host is
//  sandboxed, and its folders have one name. CI's is not, and its temporary
//  folder is `/var/folders/…` — which is where five tests failed, and what
//  named the cause. The first two tests here hold the rule on spellings
//  written by hand, so they bite in the sandbox too; the third walks a real
//  folder wherever one with two names is to be had.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct OneSpellingTests {

    /// The synchronous scan: an entry listed under the folder's other name is
    /// kept under the collection's.
    @Test func anEntryListedUnderTheOtherNameIsKeptUnderTheCollections() throws {
        let root = URL(fileURLWithPath: "/var/mobile/Containers/Notes", isDirectory: true)
        let listed = URL(fileURLWithPath: "/private/var/mobile/Containers/Notes/Sub/A note.md")
        let length = try #require(Collection.listedRootLength(of: root, in: listed),
                                  "a listing under /private/var was taken for the root's own spelling")
        #expect(Collection.respelled(listed, under: root, dropping: length).path
                == "/var/mobile/Containers/Notes/Sub/A note.md")

        // A folder stays a folder, and the other way round is the same rule.
        let folder = URL(fileURLWithPath: "/private/var/mobile/Containers/Notes/Sub", isDirectory: true)
        let kept = Collection.respelled(folder, under: root, dropping: length)
        #expect(kept.path == "/var/mobile/Containers/Notes/Sub" && kept.hasDirectoryPath)
        let long = URL(fileURLWithPath: "/private/var/mobile/Containers/Notes", isDirectory: true)
        let short = URL(fileURLWithPath: "/var/mobile/Containers/Notes/A.md")
        let other = try #require(Collection.listedRootLength(of: long, in: short))
        #expect(Collection.respelled(short, under: long, dropping: other).path
                == "/private/var/mobile/Containers/Notes/A.md")

        // The control, and the usual case: listed under the root's own name,
        // nothing is respelled — and no file pays for the question.
        #expect(Collection.listedRootLength(of: root, in: URL(fileURLWithPath: "/var/mobile/Containers/Notes/A.md")) == nil)
        // A folder that only begins like the root is not in it.
        #expect(Collection.listedRootLength(of: root, in: URL(fileURLWithPath: "/var/mobile/Containers/NotesToo/A.md")) == nil)
    }

    /// The walk: it asks once a listing whether the entries came back under
    /// another name for the folder it listed.
    @Test func theWalkSeesAListingUnderAnotherName() {
        let listed = URL(fileURLWithPath: "/private/var/mobile/Containers/Notes/Sub/A.md")
        let asked = URL(fileURLWithPath: "/var/mobile/Containers/Notes/Sub", isDirectory: true)
        #expect(LocalTreeSource.cameBackUnderAnotherName(listed, listing: asked))
        #expect(!LocalTreeSource.cameBackUnderAnotherName(
            URL(fileURLWithPath: "/var/mobile/Containers/Notes/Sub/A.md"), listing: asked))
        #expect(!LocalTreeSource.cameBackUnderAnotherName(nil, listing: asked), "an empty folder has no spelling to differ")
    }

    /// Whether this process's temporary folder has two names — it does
    /// outside the sandbox (`/var/folders/…`), and so on CI.
    nonisolated private static var temporaryFolderHasTwoNames: Bool {
        let given = FileManager.default.temporaryDirectory.path
        return given.hasPrefix("/var/") || given.hasPrefix("/private/var/")
    }

    /// A real folder with two names, walked both ways the app walks one: every
    /// note and folder is under the name the collection was opened by, and a
    /// note made in it is the note the walk then finds.
    @Test(.enabled(if: temporaryFolderHasTwoNames, "The test host's own folders have one name; CI's have two."))
    func aFolderWithTwoNamesIsWalkedUnderOne() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneSpelling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sub", isDirectory: true),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileIO.write("# A\n", to: root.appendingPathComponent("A.md"))
        try FileIO.write("# B\n", to: root.appendingPathComponent("Sub/B.md"))
        let own = root.path + "/"
        func strays(_ collection: Collection) -> [String] {
            (collection.notes.map(\.fileURL) + collection.folders).map(\.path).filter { !$0.hasPrefix(own) }
        }

        let scanned = Collection(rootURL: root)
        scanned.scan()
        try #require(scanned.notes.count == 2 && scanned.folders.count == 1)
        #expect(strays(scanned).isEmpty, "the scan kept the listing's name: \(strays(scanned))")

        let walked = Collection(rootURL: root)
        await walked.scanOffMain()
        try #require(walked.notes.count == 2 && walked.folders.count == 1)
        #expect(strays(walked).isEmpty, "the walk kept the listing's name: \(strays(walked))")

        // One note, one name: what the collection makes is what it then finds.
        let made = try #require(await walked.createNote(title: "Made"))
        await walked.scanOffMain()
        #expect(walked.notes.filter { $0.title == "Made" }.map(\.fileURL) == [made.fileURL])
    }
}

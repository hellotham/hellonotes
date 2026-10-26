//
//  MainActorLooksTests.swift
//  HelloNotesTests
//
//  A look at the disk is not part of drawing, of opening a collection, or of
//  a paste's answer: on a provider's folder, or a share that has stalled, a
//  look can wait, and on the main actor the app waited with it
//  (implemented.md §51.67).
//

import Foundation
import Synchronization
import Testing
@testable import HelloNotes
#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

@Suite(.serialized) @MainActor
struct MainActorLooksTests {

    /// **A reveal looks for its file off the main actor**, when it is asked —
    /// it looked on the main thread, at every press. The file here is not
    /// there, so nothing is handed to the Finder.
    @Test func aRevealLooksForItsFileOffTheMainActor() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hn-reveal-\(UUID().uuidString).md")
        let looks = Looks()
        FileReveal.lookProbes.withLock { $0[url.path] = { looks.add($0) } }
        defer { _ = FileReveal.lookProbes.withLock { $0.removeValue(forKey: url.path) } }

        FileReveal.reveal(url)
        var patience = Waits.Patience(.seconds(10))
        while looks.all.isEmpty, patience.lasts { try await Task.sleep(for: .milliseconds(10)) }
        #expect(looks.all == [false], "the reveal looked for its file on the main thread: \(looks.all)")
    }

    /// **Only a reveal looks for a file to reveal.** A menu built from a row's
    /// body, the file viewer's bar and the open note's actions each asked, on
    /// the main thread, as they were drawn — a look at the disk for every row.
    @Test func onlyARevealLooksForAFileToReveal() throws {
        let app = RepoFile.url("HelloNotes")
        let call = "canRe" + "veal("     // in two parts, so this file does not find itself
        let askers = (FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? [])
            .filter { $0.lastPathComponent != "FileReveal.swift" }
            .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains(call) == true }
            .map(\.lastPathComponent)
        #expect(askers.isEmpty, "a file to reveal is looked for as something is drawn, in \(askers)")
    }

    /// **A collection's identity is worked out off the main actor** where the
    /// library opens one, and where it brings one back at launch: it resolves
    /// symlinks and asks whether `/private` names something, and on a
    /// provider's folder either can wait.
    @Test(.scratchDefaults) func aCollectionsIdentityIsWorkedOutOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "hn-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Note\n".utf8).write(to: root.appending(path: "Note.md"))
        let looks = Looks()
        // Under every spelling of the folder: an unsandboxed host's temporary
        // folder has two (`/var/…` and `/private/var/…`), and a launch brings
        // a bookmarked folder back spelled the other way (implemented.md §51.68).
        let spellings = CollectionIndexCache.rootPrefixes(root).map { String($0.dropLast()) }
        Collection.identityProbes.withLock { probes in
            for path in spellings { probes[path] = { looks.add($0) } }
        }
        defer { Collection.identityProbes.withLock { probes in spellings.forEach { probes.removeValue(forKey: $0) } } }

        let defaults = ScratchDefaults.suite()
        let earlier = Library(defaults: defaults)
        await earlier.open(url: root).deactivate()
        let launch = Library(defaults: defaults)
        await launch.restore()
        launch.collections.forEach { $0.deactivate() }

        #expect(launch.collections.count == 1, "the launch brought nothing back, so it was not tested")
        #expect(looks.all == [false, false], "worked out on the main thread: \(looks.all)")
    }

    /// **A folder reached through a symlink keeps its choice of files.** The
    /// choice was written under the collection's `id` — the canonical path —
    /// and read under the root's standardized path, which a symlink spells
    /// another way, so it never came back.
    @Test func aFolderReachedThroughASymlinkKeepsItsChoiceOfFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "hn-linked-\(UUID().uuidString)", directoryHint: .isDirectory)
        let real = base.appending(path: "Real", directoryHint: .isDirectory)
        let link = base.appending(path: "Link", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let first = Collection(rootURL: link)
        defer { UserDefaults.standard.removeObject(forKey: Collection.showFilesKey(first.id)) }
        try #require(first.id != link.standardizedFileURL.path,
                     "the link and its folder are spelled alike, so this tests nothing")
        first.showsNonNoteFiles = false
        #expect(Collection(rootURL: link).showsNonNoteFiles == false, "the choice did not come back")
    }

    /// **A paste chooses its picture's name without a look at the disk**, and
    /// a name already there is the write's to find: it takes the next, and
    /// writes nothing over the picture that had it.
    @Test func aPastesNameIsChosenWithoutALookAndATakenOneIsPassedOver() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-paste-\(UUID().uuidString)", directoryHint: .isDirectory)
        let assets = dir.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let theirs = assets.appending(path: "Pasted-4000000.png")
        try Data("theirs".utf8).write(to: theirs)

        let placement = ImagePaste.place(nextTo: dir.appending(path: "Note.md"), subfolder: "assets",
                                         timestamp: Date(timeIntervalSince1970: 4_000_000))
        #expect(placement.url.lastPathComponent == "Pasted-4000000.png", "the name was chosen by a look at the disk")
        let written = try #require(await ImagePaste.write(Data([0x89, 0x52]), to: placement))
        #expect(written.markdown == "![](assets/Pasted-4000000-2.png)")
        #expect(try Data(contentsOf: theirs) == Data("theirs".utf8), "the picture already there was written over")
        #expect(try Data(contentsOf: written.url) == Data([0x89, 0x52]))
    }

    #if canImport(AppKit)
    /// **The file viewer draws without a look at the disk.** Its bar asked
    /// whether the file could be revealed — on the main thread, at every draw.
    @Test func theFileViewerDrawsWithoutALookAtTheDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hn-viewer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = dir.appending(path: "Data.csv")
        try Data("a,b\n1,2\n".utf8).write(to: csv)
        let looks = Looks()
        FileReveal.lookProbes.withLock { $0[csv.path] = { looks.add($0) } }
        defer { _ = FileReveal.lookProbes.withLock { $0.removeValue(forKey: csv.path) } }

        let viewer = FileViewerView(file: CollectionFile(url: csv, lastModified: Date()),
                                    isPlaceholder: { _ in false }, prepare: { _ in })
        // Ordered in, far off any screen, as `FileViewerDrawsTests` draws one.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: viewer.chromeDefaults())
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!looks.all.contains(true), "the viewer looked at the disk on the main thread as it drew")
    }
    #endif

    /// Which threads looked, in order: `true` for the main one.
    private final class Looks: Sendable {
        private let seen = Mutex<[Bool]>([])
        func add(_ onMainThread: Bool) { seen.withLock { $0.append(onMainThread) } }
        var all: [Bool] { seen.withLock { $0 } }
    }
}

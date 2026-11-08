//
//  QuietWalkTests.swift
//  HelloNotesTests
//
//  A walk that checks what a collection already shows says nothing about how
//  it is going (implemented.md §51.69) — on both platforms, because it was on
//  an iPhone that "Scanning …" came up at every launch and every return.
//

import Foundation
import Synchronization
import Testing
@testable import HelloNotes

@MainActor
struct QuietWalkTests {

    /// **A walk that checks a picture already on screen says nothing.** Every
    /// launch draws a collection from its cache and walks the folder to check
    /// it, and each change heard from outside walks it again; past 750 ms each
    /// said "Scanning …" and "Scanned … notes", over notes that were there all
    /// along — on an iPhone, at every launch and every return to the app. A
    /// walk with nothing yet to show still says how it is going, and so does
    /// the one someone asked for.
    @Test func aWalkThatChecksAPictureSaysNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-quiet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileIO.write("# One", to: root.appendingPathComponent("One.md"))
        try FileIO.write("# Two", to: root.appendingPathComponent("Two.md"))
        defer {
            try? FileManager.default.removeItem(at: root)
            WalkCheckpointStore.remove(for: root.standardizedFileURL.path)
        }
        let heard = Locked<[Bool]>([])
        Collection.announcementProbes.withLock { $0[root.path] = { said in heard.mutate { $0.append(said) } } }
        defer { _ = Collection.announcementProbes.withLock { $0.removeValue(forKey: root.path) } }
        let collection = Collection(rootURL: root)

        await collection.scanOffMain()             // nothing on screen yet
        await collection.scanOffMain()             // a check of what is
        await collection.rebuildFromScratch()      // Rescan: asked for
        #expect(heard.value == [true, false, true], "walks said how they were going: \(heard.value)")
    }
}

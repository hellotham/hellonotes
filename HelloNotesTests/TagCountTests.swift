//
//  TagCountTests.swift
//  HelloNotesTests
//
//  The Tags view's counts are the index's, read in a lookup: they were walked
//  over every note, once per tag, in the view's body at each pause in typing
//  — 4 ms for 223 tags and 2,027 notes, 40 ms at five tags a note
//  (implemented.md §51.36).
//

import Foundation
import Testing
@testable import HelloNotes

@Suite @MainActor
struct TagCountTests {

    @Test func aTagsCountIsTheNotesItsListHolds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TagCounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, body) in [("A", "#project and #reading"), ("B", "#project/hellonotes"),
                             ("C", "#Project/Other #project/hellonotes"), ("D", "no tags"),
                             ("E", "#reading/later")] {
            try FileIO.write("# \(name)\n\n\(body)\n", to: root.appendingPathComponent("\(name).md"))
        }
        let collection = Collection(rootURL: root)
        collection.scan()
        collection.refreshDerived(force: true)
        let search = collection.search
        let deadline = ContinuousClock.now + .seconds(10)
        while search.allTags().count < 5, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }

        // A tag's count holds the notes carrying it or a tag under it, in any
        // case — as many as `notesTagged` lists.
        for tag in search.allTags() + ["project", "PROJECT", "reading", "nothing"] {
            #expect(search.noteCountTagged(tag) == search.notesTagged(tag).count, "#\(tag)")
        }
        #expect(search.noteCountTagged("project") == 3)
        #expect(search.noteCountTagged("project/hellonotes") == 2)
        #expect(search.noteCountTagged("reading") == 2)
        #expect(search.noteCountTagged("nothing") == 0)
    }
}

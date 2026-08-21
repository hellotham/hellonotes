//
//  WikiLinkNavigationTests.swift
//  HelloNotesTests
//
//  Following a `[[wiki link]]`, tested on both platforms — which was impossible
//  while the logic lived as a `private func` on two view structs. It ran on
//  neither, and the two copies diverged to the point where the Mac resolved
//  aliases, relative paths, `[[#headings]]` and created missing notes, and the
//  iPad compared titles.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct WikiLinkNavigationTests {

    private func vault() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wikilink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ name: String, _ text: String, in root: URL) throws {
        try text.write(to: root.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
    }

    // MARK: - Splitting

    @Test func splitsTheHeadingOffTheTarget() {
        #expect(WikiLinkNavigation.split("Note").base == "Note")
        #expect(WikiLinkNavigation.split("Note").heading == nil)
        #expect(WikiLinkNavigation.split("Note#Section").base == "Note")
        #expect(WikiLinkNavigation.split("Note#Section").heading == "Section")
        // `[[Note#]]` is a typo, not a request to jump to a nameless section.
        #expect(WikiLinkNavigation.split("Note#").heading == nil)
        // A bare anchor means "this note".
        #expect(WikiLinkNavigation.split("#Section").base == "")
        #expect(WikiLinkNavigation.split("#Section").heading == "Section")
    }

    // MARK: - Resolution

    @Test func webSchemesAreOpenedRatherThanSearchedFor() async {
        for target in ["https://example.com", "http://x.test", "mailto:a@b.c"] {
            let destination = await WikiLinkNavigation.resolve(
                target: target, in: nil, current: nil)
            guard case .web(let url) = destination else {
                Issue.record("\(target) should resolve to a URL, got \(destination)")
                continue
            }
            #expect(url.absoluteString == target)
        }
    }

    /// A scheme-less target is a note name, not a URL — otherwise a note called
    /// "Roadmap" would try to open as one.
    @Test func aBareNameIsNotAURL() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Roadmap", "# Roadmap\n", in: root)
        let collection = Collection(rootURL: root)
        collection.scan()

        let destination = await WikiLinkNavigation.resolve(
            target: "Roadmap", in: collection, current: nil)
        guard case .note(let note, let heading) = destination else {
            Issue.record("expected a note, got \(destination)"); return
        }
        #expect(note.title == "Roadmap")
        #expect(heading == nil)
    }

    @Test func titlesMatchWithoutRegardToCase() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Roadmap", "# Roadmap\n", in: root)
        let collection = Collection(rootURL: root)
        collection.scan()

        let destination = await WikiLinkNavigation.resolve(
            target: "rOaDmAp", in: collection, current: nil)
        guard case .note(let note, _) = destination else {
            Issue.record("expected a note, got \(destination)"); return
        }
        #expect(note.title == "Roadmap")
    }

    @Test func aBareAnchorMeansTheNoteYouAreIn() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Here", "# Here\n\n## Section\n", in: root)
        let collection = Collection(rootURL: root)
        collection.scan()
        let current = try #require(collection.notes.first)

        let destination = await WikiLinkNavigation.resolve(
            target: "#Section", in: collection, current: current)
        guard case .note(let note, let heading) = destination else {
            Issue.record("expected this note, got \(destination)"); return
        }
        #expect(note.fileURL == current.fileURL)
        #expect(heading == "Section")
    }

    /// The behaviour the iPad's version was missing entirely: a link to a note
    /// that does not exist creates it, which is what makes `[[…]]` a way to
    /// write forwards.
    @Test func anUnknownTargetIsCreated() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Seed", "# Seed\n", in: root)
        let collection = Collection(rootURL: root)
        collection.scan()

        let destination = await WikiLinkNavigation.resolve(
            target: "Brand New", in: collection, current: nil)
        guard case .note(let note, _) = destination else {
            Issue.record("expected a created note, got \(destination)"); return
        }
        #expect(note.title == "Brand New")
        #expect(FileManager.default.fileExists(atPath: note.fileURL.path))
    }

    /// …and a caller that must not write to the vault can say so.
    @Test func createOnMissCanBeRefused() async throws {
        let root = try vault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Seed", "# Seed\n", in: root)
        let collection = Collection(rootURL: root)
        collection.scan()

        let destination = await WikiLinkNavigation.resolve(
            target: "Nothing Here", in: collection, current: nil, createOnMiss: false)
        #expect(destination == .none)
        #expect(collection.notes.count == 1, "nothing was written")
    }

    @Test func noCollectionResolvesToNothing() async {
        let destination = await WikiLinkNavigation.resolve(
            target: "Anything", in: nil, current: nil)
        #expect(destination == .none)
    }
}

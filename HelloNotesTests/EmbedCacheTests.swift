//
//  EmbedCacheTests.swift
//  HelloNotesTests
//
//  A transclusion card already drawn is served from the cache — with a look at
//  the note's date and no read of it — and the cache lets go of its oldest
//  cards, not all of them (implemented.md §51.36).
//
//  `image(forName:)` read the embedded note on every call, a coordinated read
//  of the whole of it, hit or miss, at each pause in typing in Edit and at
//  each page in Preview; and past 64 cards it emptied the cache.
//

import Foundation
import Testing
@testable import HelloNotes

@Suite @MainActor
struct EmbedCacheTests {

    /// The read is what a cached card no longer pays: the note is made
    /// unreadable without being changed, and its card still comes back.
    @Test func aCachedCardIsServedWithoutReadingTheNote() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbedCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Card.md")
        try FileIO.write("# Card\n\nWhat the card shows.\n", to: url)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let provider = CollectionEmbedProvider()
        provider.update(notes: [Note(title: "Card", fileURL: url, lastModified: Date(), fileSize: 30)])

        let first = await provider.image(forName: "Card", isDark: false)
        #expect(first != nil, "the card was not drawn, so this tests nothing")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect((try? FileIO.readString(at: url)) == nil, "the note can still be read, so this tests nothing")

        let again = await provider.image(forName: "Card", isDark: false)
        #expect(again === first, "a card already drawn read its note again")
    }

    /// Past its bound the cache lets go of the card used longest ago — not of
    /// every card, which drew all of them again at the next page.
    @Test func theCacheLetsGoOfItsOldestCard() {
        var cache = BoundedCache<String, Int>(limit: 3)
        cache["a"] = 1; cache["b"] = 2; cache["c"] = 3
        _ = cache["a"]                  // used again: now the newest
        cache["d"] = 4
        #expect(cache["b"] == nil, "the oldest was kept")
        #expect(cache["a"] == 1 && cache["c"] == 3 && cache["d"] == 4, "more than the oldest went")
        #expect(cache.count == 3)
    }
}

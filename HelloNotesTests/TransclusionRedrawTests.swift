//
//  TransclusionRedrawTests.swift
//  HelloNotesTests
//
//  Preview redraws a transclusion card when the note it shows changes.
//
//  `NotePreview` keys its page on a revision that moves when what an
//  `![[embed]]` shows may have — the collection's `derivedRevision`. It was
//  handed `collection?.derivedRevision ?? 0` by a pane that the main window
//  gives no collection (`NoteEditorView` serves note windows too), so it was
//  always 0 there, and a card redrew only when the open note itself changed
//  (implemented.md §51.36). The revision now comes with the cards, from the
//  provider that draws them, and a view showing them reads it in its own body.
//

import Foundation
import Observation
import Testing
@testable import HelloNotes

@Suite @MainActor
struct TransclusionRedrawTests {

    /// A save of a note in the collection moves the revision the cards
    /// follow, and a view reading it hears the move.
    @Test func aSaveMovesTheRevisionTheCardsFollow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Redraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let embedded = root.appendingPathComponent("Embedded.md")
        try FileIO.write("# Embedded\n\nFirst version.\n", to: embedded)
        try FileIO.write("# Host\n\n![[Embedded]]\n", to: root.appendingPathComponent("Host.md"))
        let collection = Collection(rootURL: root)
        collection.scan()
        let provider = collection.embedProvider

        let before = provider.revision
        let heard = Locked(false)
        withObservationTracking { _ = provider.revision } onChange: { heard.set(true) }

        try FileIO.write("# Embedded\n\nSecond version.\n", to: embedded)
        collection.noteDidSave(embedded, text: "# Embedded\n\nSecond version.\n")
        let deadline = ContinuousClock.now + .seconds(10)
        while !heard.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }

        #expect(heard.value, "a view showing the cards never heard that one of them changed")
        #expect(provider.revision != before)
    }

    /// A note window draws its cards from its collection's provider, which
    /// follows the collection's notes and its saves; one of the window's own
    /// was filled once, when the window opened, and followed nothing.
    @Test func aCollectionsProviderIsTheCollections() {
        let collection = Collection(rootURL: FileManager.default.temporaryDirectory)
        #expect(collection.embedProvider.owner === collection)
        #expect(CollectionEmbedProvider().revision == 0)
    }
}

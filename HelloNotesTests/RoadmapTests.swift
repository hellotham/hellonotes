//
//  RoadmapTests.swift
//  HelloNotesTests
//
//  Automated coverage for the native-integration code (URL deep-link parsing,
//  the widget App-Group snapshot, deep links). The device-only surfaces
//  (SpeechAnalyzer mic capture, Foundation Models, iCloud multi-device sync)
//  can't be unit-tested, but the pure logic that feeds them is exercised here.
//

import Testing
import Foundation
@testable import HelloNotes

struct URLRouterTests {
    @Test func parsesNoteByPath() {
        let d = URLRouter.destination(for: URL(string: "hellonotes://note?collection=Vault&path=Sub/Note.md")!)
        #expect(d == .note(collection: "Vault", ref: .path("Sub/Note.md")))
    }

    @Test func parsesNoteByTitle() {
        let d = URLRouter.destination(for: URL(string: "hellonotes://note?collection=Vault&title=My%20Note")!)
        #expect(d == .note(collection: "Vault", ref: .title("My Note")))
    }

    @Test func parsesCollectionSearchNewDaily() {
        #expect(URLRouter.destination(for: URL(string: "hellonotes://collection?name=Vault")!) == .collection("Vault"))
        #expect(URLRouter.destination(for: URL(string: "hellonotes://search?q=todo")!) == .search("todo"))
        #expect(URLRouter.destination(for: URL(string: "hellonotes://new?title=Idea")!) == .newNote(collection: nil, title: "Idea"))
        #expect(URLRouter.destination(for: URL(string: "hellonotes://daily")!) == .dailyNote)
    }

    @Test func rejectsForeignSchemeAndIncompleteURLs() {
        #expect(URLRouter.destination(for: URL(string: "https://example.com/note")!) == nil)
        #expect(URLRouter.destination(for: URL(string: "hellonotes://note")!) == nil)      // no collection
        #expect(URLRouter.destination(for: URL(string: "hellonotes://bogus")!) == nil)     // unknown host
    }
}

struct WidgetSnapshotTests {
    @Test func itemDeepLinkPointsAtTheNote() {
        let item = WidgetSnapshot.Item(title: "My Note", collectionName: "Vault",
                                       relativePath: "Sub/Note.md", modified: .init(timeIntervalSince1970: 1))
        #expect(item.deepLink.hasPrefix("hellonotes://note?"))
        #expect(item.deepLink.contains("collection=Vault"))
        #expect(item.deepLink.contains("path=Sub/Note.md") || item.deepLink.contains("path=Sub%2FNote.md"))
        // And the router parses it straight back to the same note.
        #expect(URLRouter.destination(for: URL(string: item.deepLink)!)
            == .note(collection: "Vault", ref: .path("Sub/Note.md")))
    }

    @Test func snapshotCodableRoundTrip() throws {
        let item = WidgetSnapshot.Item(title: "A", collectionName: "V", relativePath: "a.md",
                                       modified: .init(timeIntervalSince1970: 10))
        let snapshot = WidgetSnapshot(recents: [item], focusedCollection: "V",
                                      generatedAt: .init(timeIntervalSince1970: 20))
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded.recents.count == 1)
        #expect(decoded.recents.first?.title == "A")
        #expect(decoded.focusedCollection == "V")
    }
}

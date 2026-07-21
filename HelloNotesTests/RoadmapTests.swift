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

/// Cloud-native I/O (Phases 0–1). The dataless/online-only path needs a real
/// File Provider volume and can't be unit-tested, but the coordinated read/write
/// round-trip and the critical "local files are always available" invariant are.
struct FileIOTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hn-fileio-\(UUID().uuidString).md")
    }

    @Test func coordinatedWriteThenReadRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileIO.write("# Hello\n\nBody with unicode: café ☕️", to: url)
        #expect(try FileIO.readString(at: url) == "# Hello\n\nBody with unicode: café ☕️")
    }

    @Test func createRefusesToOverwrite() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileIO.create(Data("first".utf8), at: url)
        #expect(throws: (any Error).self) { try FileIO.create(Data("second".utf8), at: url) }
        #expect(try FileIO.readString(at: url) == "first")   // unchanged
    }

    @Test func writeReplacesExistingContent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileIO.write("old", to: url)
        try FileIO.write("new", to: url)
        #expect(try FileIO.readString(at: url) == "new")
    }

    /// The no-regression invariant that Phase 1's indexing guards depend on: an
    /// ordinary local file is never treated as online-only, so it is always
    /// indexed (never skipped as if it were an un-downloaded cloud file).
    @Test func localFileIsAlwaysMaterialized() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileIO.write("local", to: url)
        #expect(FileIO.isMaterialized(at: url) == true)
    }
}

//
//  LaunchRestoreTests.swift
//  HelloNotesTests
//
//  The launch brings back every collection it was asked to, and writes the
//  open lists only once they are all back (implemented.md §51.72).
//
//  A local collection's bookmark that resolved stale — its folder renamed or
//  moved — was minted again and written back at once, before the cloud
//  collections were restored. `persist()` writes both lists from the
//  collections open at that moment, so the list of cloud collections was
//  written empty just before it was read: every cloud collection dropped for
//  good, with whatever its cache had not yet sent.
//
//  The launch is staged in defaults of the test's own (`Library(defaults:)`),
//  and the cloud collection's provider is never reached: the account is one
//  no Keychain holds, so its first refresh stops at "not signed in".
//

import Foundation
import Testing
@testable import HelloNotes

@Suite(.serialized) @MainActor
struct LaunchRestoreTests {

    /// **A launch that mints a bookmark again keeps the cloud collections.**
    /// The control is the bookmark itself: it must come back stale, or nothing
    /// is minted and the test passes for a reason that is not its own.
    @Test(.scratchDefaults) func aRefreshedBookmarkKeepsTheCloudCollections() async throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "LaunchRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let defaults = ScratchDefaults.suite()

        // A local collection open at the last quit, whose folder has been
        // renamed since: its bookmark resolves, and resolves stale.
        let local = base.appending(path: "Local", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("# Note\n\nAs written.\n".utf8).write(to: local.appending(path: "Note.md"))
        let earlier = Library(defaults: defaults)
        await earlier.open(url: local).deactivate()
        try FileManager.default.moveItem(at: local, to: base.appending(path: "Local, renamed", directoryHint: .isDirectory))
        let bookmark = try #require((defaults.array(forKey: "collectionBookmarks") as? [Data])?.first,
                                    "the local collection was not remembered in the test's defaults")
        try #require(Bookmark.resolveRefreshing(bookmark)?.refreshed != nil,
                     "the bookmark did not resolve stale, so the launch mints nothing and this tests nothing")

        // A cloud collection open at the last quit: its cache, and the list
        // that names it.
        let cache = base.appending(path: "Cache", directoryHint: .isDirectory)
        RemoteManifest(provider: "Dropbox", accountID: "hn-test-\(UUID().uuidString)",
                       remoteRoot: "/Notes", displayName: "Notes").save(toCacheRoot: cache)
        defaults.set([cache.path], forKey: "remoteCollectionCaches")

        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        await library.restore()

        #expect(library.collections.contains { $0.remote != nil },
                "the cloud collection was not brought back")
        let kept = (defaults.array(forKey: "remoteCollectionCaches") as? [String]) ?? []
        #expect(kept.map { URL(filePath: $0).lastPathComponent } == ["Cache"],
                "the list of cloud collections was written without it — \(kept.count) entries")
        #expect(library.collections.contains { collection in
                    guard collection.remote == nil else { return false }
                    if case .unavailable = collection.state { return false }
                    return collection.rootURL.lastPathComponent == "Local, renamed"
                }, "the local collection was not brought back from its renamed folder")
    }
}

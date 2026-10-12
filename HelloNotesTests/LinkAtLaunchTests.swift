//
//  LinkAtLaunchTests.swift
//  HelloNotesTests
//
//  A link that launches the app opens its note.
//
//  It did not. A `hellonotes://` link is handed to the router as soon as there
//  is a window, and the window's first work is bringing back what was open at
//  the last quit — resolving bookmarks off the main actor, then reading each
//  collection. Resolved at once, the link named a collection that was not open
//  yet, found nothing, and was dropped: the app came up on whatever it showed
//  last. The widget's links are this kind, so a tap on the widget with the app
//  closed did nothing a tap on its icon would not have (measured through
//  Accessibility on 2026-10-12: one window, no tab for the note; the same link
//  to a running app opened it).
//
//  The router holds what it could not resolve while the library is still
//  coming back, and tries it once more when the launch settles
//  (`Library.launchDidSettle`). What still names nothing then is dropped, as
//  a link to nothing always was.
//
//  Each test is the launch as it happens: a library that reads "what was open"
//  from a defaults store of the test's own, the link first, the restore after.
//

import Foundation
import Testing
@testable import HelloNotes

@Suite(.serialized) @MainActor
struct LinkAtLaunchTests {

    // MARK: - The link arrives first

    /// The link, then the restore, then the launch settling: the note is asked
    /// for. Before the fix nothing ever asked.
    @Test(.scratchDefaults) func aLinkThatArrivesBeforeTheLibraryIsBackOpensItsNote() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library)

        let resolved = await router.route(.note(collection: root.lastPathComponent, ref: .title("Writing")))
        #expect(!resolved, "nothing is open yet, so there is nothing to resolve it against")
        #expect(library.pendingOpenNoteID == nil)

        await library.restore()
        // The control: the collection is back and read, so the link *could*
        // be resolved now — whatever follows is not for want of the note.
        let note = try #require(library.collections.first?.note(titled: "Writing"))
        #expect(library.pendingOpenNoteID == nil, "nothing opens before the launch has settled")

        library.launchDidSettle()
        #expect(await eventually { library.pendingOpenNoteID == note.fileURL },
                "the link that launched the app was dropped")
    }

    /// Two links before the library is back: the last is where the person
    /// meant to go.
    @Test(.scratchDefaults) func theLastLinkBeforeTheLibraryIsBackIsTheOneOpened() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library)
        let name = root.lastPathComponent

        await router.route(.note(collection: name, ref: .title("Writing")))
        await router.route(.note(collection: name, ref: .path("Linking.md")))
        await library.restore()
        let linking = try #require(library.collections.first?.note(titled: "Linking"))
        library.launchDidSettle()

        #expect(await eventually { library.pendingOpenNoteID == linking.fileURL })
    }

    /// A link held, then one that *resolves* before the launch settles — the
    /// later one is where the person meant to go, and settling must not open
    /// the earlier over it. Resolving did not clear what was held.
    @Test(.scratchDefaults) func aLinkThatResolvesEndsAnEarlierOneStillHeld() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library)
        let name = root.lastPathComponent

        #expect(await router.route(.note(collection: name, ref: .title("Writing"))) == false)   // held
        await library.restore()
        let linking = try #require(library.collections.first?.note(titled: "Linking"))
        // The library is back and the launch has not settled: this one resolves.
        #expect(await router.route(.note(collection: name, ref: .path("Linking.md"))))
        #expect(library.pendingOpenNoteID == linking.fileURL)

        library.launchDidSettle()
        await pump(0.3)
        #expect(library.pendingOpenNoteID == linking.fileURL,
                "the link held from before opened over the one followed after it")
    }

    /// The other kinds of link wait the same way: a new note asked for before
    /// there is a collection to make it in is made once there is.
    @Test(.scratchDefaults) func aNewNoteAskedForBeforeTheLibraryIsBackIsMadeOnceItIs() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library)

        let resolved = await router.route(.newNote(collection: nil, title: "From a Link"))
        #expect(!resolved)
        await library.restore()
        library.launchDidSettle()

        #expect(await eventually { library.pendingOpenNoteID?.lastPathComponent == "From a Link.md" },
                "the note the link asked for was never made")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "From a Link.md").path))
    }

    // MARK: - What must not change

    /// A link to a note that is not there is dropped when the library is back
    /// — not held for a note of that name to turn up later.
    @Test(.scratchDefaults) func aLinkToWhatIsNotThereIsDropped() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library)

        await router.route(.note(collection: root.lastPathComponent, ref: .title("No Such Note")))
        await library.restore()
        library.launchDidSettle()
        await pump(0.2)
        #expect(library.pendingOpenNoteID == nil)

        // And it is gone for good: the note appearing afterwards opens nothing.
        let collection = try #require(library.collections.first)
        _ = await collection.createNote(title: "No Such Note")
        await pump(0.2)
        #expect(library.pendingOpenNoteID == nil, "a link dropped at launch came back when its note was made")
    }

    /// Once the launch has settled a link is resolved at once, as it always
    /// was, and one that names nothing is not held.
    @Test(.scratchDefaults) func aLinkAfterTheLaunchIsResolvedAtOnce() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library)
        await library.restore()
        library.launchDidSettle()
        let note = try #require(library.collections.first?.note(titled: "Writing"))

        #expect(await router.route(.note(collection: root.lastPathComponent, ref: .title("Writing"))))
        #expect(library.pendingOpenNoteID == note.fileURL)
        #expect(await router.route(.note(collection: "Not Open", ref: .title("Writing"))) == false)
    }

    /// A link held past its time is no longer what the person is doing: the
    /// launch settling does not open it. (Held for no time at all here; two
    /// minutes in the app.)
    @Test(.scratchDefaults) func aLinkHeldTooLongIsNotOpened() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library, holdsFor: .zero)

        await router.route(.note(collection: root.lastPathComponent, ref: .title("Writing")))
        await library.restore()
        _ = try #require(library.collections.first?.note(titled: "Writing"))
        library.launchDidSettle()
        await pump(0.2)
        #expect(library.pendingOpenNoteID == nil)
    }

    /// An intent that opens the app to show a note calls `selectNote`, not
    /// `route` — and runs just as early.
    @Test(.scratchDefaults) func aNoteAskedForByAnIntentBeforeTheLibraryIsBackIsShown() async throws {
        let (root, defaults) = try await aCollectionOpenAtTheLastQuit()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(defaults: defaults)
        defer { library.collections.forEach { $0.deactivate() } }
        let router = NavigationRouter(library: library)

        #expect(!router.selectNote(collectionNamed: root.lastPathComponent, ref: .path("Linking.md")))
        await library.restore()
        let linking = try #require(library.collections.first?.note(titled: "Linking"))
        library.launchDidSettle()
        #expect(await eventually { library.pendingOpenNoteID == linking.fileURL })
    }

    // MARK: - The launch

    /// A folder of two notes that a library opened and then went away from —
    /// which is what "open at the last quit" is: its bookmark and its path in
    /// the defaults the next library reads. The defaults are the test's own.
    private func aCollectionOpenAtTheLastQuit() async throws -> (root: URL, defaults: UserDefaults) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LinkAtLaunch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["Writing", "Linking"] {
            try Data("# \(name)\n\nAs written.\n".utf8).write(to: root.appending(path: "\(name).md"))
        }
        let defaults = ScratchDefaults.suite()
        let earlier = Library(defaults: defaults)
        let collection = await earlier.open(url: root)
        collection.deactivate()
        // Or the launch below restores nothing, and every test here passes or
        // fails for a reason that is not its own.
        try #require((defaults.array(forKey: "collectionBookmarks") as? [Data])?.count == 1,
                     "the collection was not remembered in the test's defaults")
        return (root, defaults)
    }

    private func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}

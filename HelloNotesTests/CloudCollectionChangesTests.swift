//
//  CloudCollectionChangesTests.swift
//  HelloNotesTests
//
//  A cloud collection is a local mirror of a provider's folder
//  (`RemoteMirror`), and a change made in it has to reach the provider. Only
//  an edit to a note downloaded from the provider did: a note made here was
//  refused at its first save ("hasn't been downloaded … yet") because the
//  mirror's manifest knew no such path, and a rename, a move, a copy or a new
//  folder changed the mirror alone — so the provider kept the old name, which
//  came back at the next sync, and the rest lived on one device only.
//
//  Each case goes through the collection as the app drives it, against a
//  provider as strict about folders as Box and Google Drive, which issues a
//  revision per write, the way the real ones let the mirror see a change made
//  elsewhere. The controls — a downloaded note still uploads, a placeholder is
//  still never uploaded — held before and hold now.
//

import Foundation
import Testing
@testable import HelloNotes

@MainActor
struct CloudCollectionChangesTests {

    // MARK: - Harness

    /// A cloud collection as the app opens one: the provider's folder mirrored
    /// (its shape — every note a placeholder until something opens it) and the
    /// collection walked.
    private func cloudCollection(_ store: StrictFolderStore = StrictFolderStore())
        async throws -> (collection: Collection, store: StrictFolderStore, cache: URL) {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hn-cloud-\(UUID().uuidString)")
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Test cloud")
        try await mirror.syncMetadata()
        let collection = Collection(rootURL: cache)
        collection.remote = mirror
        await collection.scanOffMain()
        return (collection, store, cache)
    }

    /// Everything the collection has asked of the provider so far, done.
    private func sent(_ collection: Collection) async {
        await collection.remote?.changesSent()
    }

    /// What the editor does on a save: the text written, then the collection told.
    private func save(_ text: String, to url: URL, in collection: Collection) throws {
        try FileIO.write(text, to: url)
        collection.noteDidSave(url, text: text)
    }

    private func note(_ title: String, in collection: Collection) throws -> Note {
        try #require(collection.note(titled: title), "no note titled \(title)")
    }

    private func text(at url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func conflictedCopies(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.contains("conflicted copy") }
    }

    private static let welcome = "# Welcome\n\nFrom the provider.\n"

    // MARK: - A note made here

    /// The report: a note made in a cloud collection and saved never reached
    /// the provider — each save was refused, with a message about downloading
    /// that is wrong for a note that was never anywhere else.
    @Test func aNoteMadeHereReachesTheProviderWhenItIsSaved() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let made = try #require(await collection.createNote(title: "Made here"))

        try save("# Made here\n\nWritten here.\n", to: made.fileURL, in: collection)
        await sent(collection)
        #expect(store.text(at: "/Made here.md") == "# Made here\n\nWritten here.\n",
                "a note made here never reached the provider")
        #expect(collection.lastError == nil, "the save was refused: \(collection.lastError ?? "")")
    }

    /// A note made here exists everywhere from the moment it is made, like one
    /// made in any other folder — not only once something is typed into it.
    @Test func aNoteMadeHereReachesTheProviderAsSoonAsItIsMade() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        _ = try #require(await collection.createNote(title: "Just made"))

        await sent(collection)
        #expect(store.text(at: "/Just made.md") == "", "a new note is not on the provider")
    }

    /// Once up, a note made here is a note the provider knows: the next save
    /// is an ordinary one, not a conflict with its own first upload.
    @Test func aNoteMadeHereSavesAgainWithoutAConflict() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let made = try #require(await collection.createNote(title: "Made here"))
        try save("# Made here\n\nFirst.\n", to: made.fileURL, in: collection)
        await sent(collection)

        try save("# Made here\n\nSecond.\n", to: made.fileURL, in: collection)
        await sent(collection)
        #expect(store.text(at: "/Made here.md") == "# Made here\n\nSecond.\n")
        #expect(conflictedCopies(in: cache).isEmpty, "a second save conflicted with the first")
        #expect(store.paths.filter { $0.contains("conflicted copy") }.isEmpty)
        #expect(collection.lastError == nil, "\(collection.lastError ?? "")")
    }

    /// A note made here under a name another device gave a note of its own
    /// since this one last looked: neither is written over. The clash is met
    /// when the note is made — its first upload — and said; theirs goes beside
    /// mine, here and on the provider, and mine takes the name with its save.
    @Test func aNoteMadeHereUnderANameMadeElsewhereKeepsBoth() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        store.put("# Theirs\n", at: "/Shared name.md")      // another device, unseen here
        let made = try #require(await collection.createNote(title: "Shared name"))
        await sent(collection)

        #expect(collection.lastError?.contains("also made") == true, "the clash was not reported")
        #expect(store.text(at: "/Shared name.md") == "# Theirs\n", "theirs was written over without a word")
        let copies = conflictedCopies(in: cache)
        #expect(copies.count == 1, "theirs was not kept beside mine: \(copies)")
        if let copy = copies.first {
            #expect(text(at: cache.appending(path: copy)) == "# Theirs\n")
            #expect(store.text(at: "/" + copy) == "# Theirs\n", "theirs, kept beside mine, is on this device only")
        }

        try save("# Mine\n", to: made.fileURL, in: collection)
        await sent(collection)
        #expect(text(at: made.fileURL) == "# Mine\n", "mine was replaced")
        #expect(store.text(at: "/Shared name.md") == "# Mine\n", "mine never took the name")
    }

    /// The control: a note downloaded from the provider uploads as it always did.
    @Test func aNoteDownloadedFromTheProviderStillUploads() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        #expect(text(at: welcome.fileURL) == Self.welcome)

        try save("# Welcome\n\nEdited here.\n", to: welcome.fileURL, in: collection)
        await sent(collection)
        #expect(store.text(at: "/Welcome.md") == "# Welcome\n\nEdited here.\n")
        #expect(collection.lastError == nil, "\(collection.lastError ?? "")")
    }

    /// The other control, and the guard that must keep holding: a placeholder
    /// — the empty stand-in for a note not downloaded — is never uploaded over
    /// the note it stands in for.
    @Test func aPlaceholderIsStillNeverUploaded() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        #expect(collection.isPlaceholder(at: welcome.fileURL), "Welcome is not a placeholder, so this tests nothing")

        collection.noteDidSave(welcome.fileURL, text: "")
        await sent(collection)
        #expect(store.text(at: "/Welcome.md") == Self.welcome, "a placeholder was uploaded over the note")
        #expect(collection.lastError?.contains("hasn't been downloaded") == true)
    }

    // MARK: - Renamed, moved

    /// A rename moved the file here and nowhere else: the provider kept the
    /// old name, and the mirror's record of the note stayed under it.
    @Test func aRenamedNoteIsRenamedOnTheProvider() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)

        _ = try #require(await collection.renameNote(welcome, to: "Hello"))
        await sent(collection)
        #expect(store.text(at: "/Hello.md") == Self.welcome, "the provider does not have the new name")
        #expect(store.text(at: "/Welcome.md") == nil, "the provider still has the old name")
    }

    /// Renamed before it was ever opened: moved on the provider without being
    /// downloaded, and still a placeholder here — which opens from its new name.
    @Test func aNoteNotYetDownloadedIsRenamedWithoutDownloadingIt() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        let reads = store.reads

        let hello = try #require(await collection.renameNote(welcome, to: "Hello"))
        await sent(collection)
        #expect(store.text(at: "/Hello.md") == Self.welcome)
        #expect(store.text(at: "/Welcome.md") == nil)
        #expect(store.reads == reads, "renaming downloaded the note")
        #expect(collection.isPlaceholder(at: hello.fileURL), "the renamed stand-in was taken for the note")

        await collection.hydrateIfNeeded(hello.fileURL)
        #expect(text(at: hello.fileURL) == Self.welcome, "the renamed note does not open")
    }

    /// Saved under its new name, a renamed note uploads — to the new name.
    @Test func aRenamedNoteSavesUnderItsNewName() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        let hello = try #require(await collection.renameNote(welcome, to: "Hello"))

        try save("# Hello\n\nSaved after the rename.\n", to: hello.fileURL, in: collection)
        await sent(collection)
        #expect(store.text(at: "/Hello.md") == "# Hello\n\nSaved after the rename.\n")
        #expect(store.text(at: "/Welcome.md") == nil)
        #expect(collection.lastError == nil, "\(collection.lastError ?? "")")
    }

    /// The next full sync does not bring an old name back. For a note not yet
    /// downloaded it did, as a placeholder, because the provider still had the
    /// name; for one downloaded the mirror went on recording a download no
    /// longer here, under the name it no longer had.
    @Test func aSyncAfterARenameDoesNotBringTheOldNameBack() async throws {
        let (collection, _, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        let idea = try note("Idea", in: collection)          // not downloaded
        await collection.hydrateIfNeeded(welcome.fileURL)
        let hello = try #require(await collection.renameNote(welcome, to: "Hello"))
        let thought = try #require(await collection.renameNote(idea, to: "Thought"))
        await sent(collection)

        try await mirror.syncMetadata()
        #expect(!FileManager.default.fileExists(atPath: idea.fileURL.path), "the old name came back")
        #expect(mirror.manifest.entries["Welcome.md"] == nil, "the mirror still records the old name")
        #expect(mirror.manifest.entries["Notes/Idea.md"] == nil, "the mirror still records the old name")
        #expect(text(at: hello.fileURL) == Self.welcome)
        #expect(!collection.isPlaceholder(at: hello.fileURL))
        #expect(collection.isPlaceholder(at: thought.fileURL), "a note never downloaded became its placeholder")
    }

    @Test func aNoteMovedIntoAFolderMovesOnTheProvider() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)

        _ = try #require(await collection.moveItem(at: welcome.fileURL, into: cache.appending(path: "Notes")))
        await sent(collection)
        #expect(store.text(at: "/Notes/Welcome.md") == Self.welcome)
        #expect(store.text(at: "/Welcome.md") == nil)
    }

    /// New Note, then its title typed — a rename — then its first words saved:
    /// one note, at the name it was given, however fast the three follow.
    @Test func aNewNoteNamedAtOnceArrivesUnderItsName() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let untitled = try #require(await collection.createNote())
        let named = try #require(await collection.renameNote(untitled, to: "Named"))
        try save("# Named\n", to: named.fileURL, in: collection)

        await sent(collection)
        #expect(store.text(at: "/Named.md") == "# Named\n")
        #expect(store.text(at: "/Untitled.md") == nil, "the name it was made with is left on the provider")
    }

    // MARK: - Copied

    /// A copy of a note not yet downloaded was a copy of its placeholder: an
    /// empty note under the copy's name.
    @Test func aCopyOfANoteNotYetDownloadedCarriesItsText() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)

        let copy = try #require(await collection.duplicateNote(welcome))
        #expect(text(at: copy.fileURL) == Self.welcome, "the copy is of the placeholder, not the note")
        await sent(collection)
        #expect(store.text(at: "/Welcome copy.md") == Self.welcome, "the copy is on this device only")
    }

    // MARK: - Folders

    @Test func aFolderMadeHereIsMadeOnTheProvider() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        _ = try #require(await collection.createFolder(named: "Projects"))

        await sent(collection)
        #expect(store.hasFolder("/Projects"), "the folder is on this device only")
    }

    /// Box and Google Drive put a file only into a folder that exists, so a
    /// note in a folder made here needs the folder made there first.
    @Test func aNoteMadeInAFolderMadeHereReachesTheProvider() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let folder = try #require(await collection.createFolder(named: "Projects"))
        let made = try #require(await collection.createNote(title: "Plan", in: folder))
        try save("# Plan\n", to: made.fileURL, in: collection)

        await sent(collection)
        #expect(store.text(at: "/Projects/Plan.md") == "# Plan\n")
        #expect(collection.lastError == nil, "\(collection.lastError ?? "")")
    }

    /// A daily note, made with its folder when the day's first one is.
    @Test func aDailyNoteInAFolderNotYetMadeReachesTheProvider() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        _ = try #require(await collection.note(atRelativePath: "Journal/2026-09-27.md",
                                               creatingWith: "# 27 September\n"))
        await sent(collection)
        #expect(store.hasFolder("/Journal"))
        #expect(store.text(at: "/Journal/2026-09-27.md") == "# 27 September\n")
    }

    // MARK: - Deleted

    /// A note deleted here leaves the mirror's record too. The record stayed —
    /// downloaded, as far as it said — so trimming the cache wrote an empty
    /// file back at the deleted note's name.
    @Test func aDeletedNoteLeavesNothingBehind() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)

        await collection.deleteNote(welcome)
        await sent(collection)
        #expect(store.text(at: "/Welcome.md") == nil)
        #expect(mirror.manifest.entries["Welcome.md"] == nil, "the mirror still records the deleted note")
        await mirror.evictIfNeeded(limit: 0)
        #expect(!FileManager.default.fileExists(atPath: welcome.fileURL.path), "trimming the cache brought the note back")
    }

    // MARK: - Written by the app

    /// The copy of mine an editor keeps beside a note when a conflict is open
    /// and its buffer is let go (implemented.md §51.16), which the collection
    /// hears of as a save.
    @Test func theCopyAnEditorKeepsBesideANoteReachesTheProvider() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)

        let mine = "# Welcome\n\nMine, kept beside it.\n"
        let kept = try FileIO.createConflictedCopy(beside: welcome.fileURL, holding: Data(mine.utf8))
        collection.noteDidSave(kept, text: mine)
        await sent(collection)
        #expect(store.text(at: "/" + kept.lastPathComponent) == mine, "the copy kept beside the note is on this device only")
    }

    /// A rename rewrites the links to the note in the notes that hold them —
    /// here, and so on the provider.
    @Test func aLinkRewrittenByARenameReachesTheProvider() async throws {
        let store = StrictFolderStore()
        store.put("See [[Welcome]].\n", at: "/Linker.md")
        let (collection, _, cache) = try await cloudCollection(store)
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        let linker = try note("Linker", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        await collection.hydrateIfNeeded(linker.fileURL)
        collection.refreshDerived()
        #expect(await eventually { collection.linkGraph.backlinksByURL[welcome.fileURL]?.contains(linker.fileURL) == true },
                "the link to Welcome was never indexed, so this tests nothing")

        _ = try #require(await collection.renameNote(welcome, to: "Hello"))
        #expect(await eventually { self.text(at: linker.fileURL) == "See [[Hello]].\n" }, "the link was not rewritten")
        // The rewrite follows the rename in the background, and hands its
        // saves over once every note is written.
        #expect(await eventually {
            await self.sent(collection)
            return store.text(at: "/Linker.md") == "See [[Hello]].\n"
        }, "the rewritten link is on this device only")
    }

    /// Quick capture into a note not yet downloaded appended to its
    /// placeholder: the note became the appended line, and the next download
    /// put the note back over it.
    @Test func appendingToANoteNotYetDownloadedKeepsItsText() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)

        await collection.append("- one more\n", to: welcome)
        await sent(collection)
        #expect(text(at: welcome.fileURL) == Self.welcome + "- one more\n", "the append replaced the note")
        #expect(store.text(at: "/Welcome.md") == Self.welcome + "- one more\n")
    }

    // MARK: - While the provider could not be reached

    /// Made while the provider could not be reached: the upload fails and says
    /// so, and the note goes up with the next refresh rather than only if it is
    /// edited again.
    @Test func aNoteMadeWhileOfflineGoesUpAtTheNextRefresh() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        store.isReachable = false
        let made = try #require(await collection.createNote(title: "Offline"))
        try save("# Offline\n", to: made.fileURL, in: collection)
        await sent(collection)
        #expect(collection.lastError != nil, "a failed upload was not reported")

        store.isReachable = true
        await collection.refreshFromProvider()
        await sent(collection)
        #expect(store.text(at: "/Offline.md") == "# Offline\n", "a note made offline stayed on this device")
    }

    // MARK: - While a sync walks

    /// A note made and saved while a full sync walks the provider's folder is
    /// one the walk has not listed. It is not the provider's to delete: the
    /// sync keeps it, its uploads take their turns after the walk, and the
    /// mirror's record of it survives — or its next save would conflict with
    /// its own first upload.
    @Test func aNoteMadeWhileASyncWalksIsKeptAndSent() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let (reached, resume) = store.holdListing(of: "/Notes")
        let sync = Task { try await mirror.syncMetadata() }
        await reached.wait()

        let made = try #require(await collection.createNote(title: "Made mid-sync"))
        try save("# Made mid-sync\n", to: made.fileURL, in: collection)
        resume.open()
        _ = try await sync.value
        await sent(collection)

        #expect(FileManager.default.fileExists(atPath: made.fileURL.path), "the sync deleted a note made while it walked")
        #expect(!collection.isPlaceholder(at: made.fileURL))
        #expect(mirror.manifest.entries["Made mid-sync.md"]?.hydrated == true, "the sync dropped the mirror's record")
        try save("# Made mid-sync\n\nAgain.\n", to: made.fileURL, in: collection)
        await sent(collection)
        #expect(store.text(at: "/Made mid-sync.md") == "# Made mid-sync\n\nAgain.\n")
        #expect(conflictedCopies(in: cache).isEmpty, "the next save conflicted with the note's own upload")
    }

    /// Made here, still empty, while a full sync walks — under a name another
    /// device gave a note the cache has not seen yet (two devices'
    /// "Untitled"). The walk took the new note for the provider's
    /// placeholder: its uploads were refused as never downloaded, its saves
    /// were never marked unsent, and opening it, as the refusal advises,
    /// downloaded theirs over what was typed. It is a note made here under a
    /// name made elsewhere too, and both are kept.
    @Test func aNoteMadeWhileASyncWalksUnderANameMadeElsewhereKeepsBoth() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        store.put("# Theirs\n", at: "/Untitled.md")
        let (reached, resume) = store.holdListing(of: "")
        let sync = Task { try await mirror.syncMetadata() }
        await reached.wait()

        let made = try #require(await collection.createNote(title: "Untitled"))
        resume.open()
        _ = try await sync.value
        try save("# Mine\n", to: made.fileURL, in: collection)
        await sent(collection)

        #expect(!collection.isPlaceholder(at: made.fileURL), "the walk took a note made here for the provider's placeholder")
        await collection.hydrateIfNeeded(made.fileURL)
        #expect(text(at: made.fileURL) == "# Mine\n", "opening the note downloaded theirs over what was typed")
        let copies = conflictedCopies(in: cache)
        #expect(copies.count == 1, "theirs was not kept beside mine: \(copies)")
        if let copy = copies.first { #expect(text(at: cache.appending(path: copy)) == "# Theirs\n") }
        #expect(store.text(at: "/Untitled.md") == "# Mine\n", "mine never reached the provider")
    }

    /// Opened — downloaded — while a full sync walks: still downloaded when it
    /// ends. The sync wrote back the record it started with, which said
    /// "placeholder": the note's saves were refused from then on, and the next
    /// open downloaded it again over what was typed.
    @Test func aNoteDownloadedWhileASyncWalksStaysDownloaded() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        let (reached, resume) = store.holdListing(of: "/Notes")
        let sync = Task { try await mirror.syncMetadata() }
        await reached.wait()

        await collection.hydrateIfNeeded(welcome.fileURL)
        resume.open()
        _ = try await sync.value
        #expect(!collection.isPlaceholder(at: welcome.fileURL), "the sync marked a downloaded note a placeholder again")
        #expect(text(at: welcome.fileURL) == Self.welcome)
    }

    /// Downloaded while a walk recorded a newer revision of it: the bytes on
    /// their way were the older one, and they were kept as the newer — so the
    /// next save passed the conflict check and wrote over the provider's newer
    /// copy. The download is asked for again.
    @Test func aDownloadOvertakenByANewerRevisionIsFetchedAgain() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        let (reached, resume) = store.holdRead(of: "/Welcome.md")
        let opening = Task { await collection.hydrateIfNeeded(welcome.fileURL) }
        await reached.wait()

        store.put("# Welcome, changed elsewhere\n", at: "/Welcome.md")
        try await mirror.syncMetadata()
        resume.open()
        await opening.value
        #expect(text(at: welcome.fileURL) == "# Welcome, changed elsewhere\n",
                "the older bytes were kept as the newer revision")
        #expect(!collection.isPlaceholder(at: welcome.fileURL))
    }

    /// Renamed while a full sync walks, the walk listing the folder after the
    /// rename was made here and before its turn made it on the provider: the
    /// walk sees the old name, and must not put it back — neither a
    /// placeholder under it here nor a record of it.
    @Test func aNoteRenamedWhileASyncWalksKeepsItsNewName() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        let (reached, resume) = store.holdListing(of: "")
        let sync = Task { try await mirror.syncMetadata() }
        await reached.wait()

        let hello = try #require(await collection.renameNote(welcome, to: "Hello"))
        resume.open()
        _ = try await sync.value
        #expect(!FileManager.default.fileExists(atPath: welcome.fileURL.path),
                "the walk put a placeholder back under the old name")
        await sent(collection)
        #expect(mirror.manifest.entries["Welcome.md"] == nil, "the sync put the old name back in the record")
        #expect(!FileManager.default.fileExists(atPath: welcome.fileURL.path), "the sync put the old name back")
        #expect(mirror.manifest.entries["Hello.md"]?.hydrated == true)
        #expect(text(at: hello.fileURL) == Self.welcome)
        #expect(store.text(at: "/Hello.md") == Self.welcome)
    }

    /// Deleted while a full sync walks, before the walk lists its folder: gone
    /// for good — no placeholder put back under its name, no record — and
    /// deleted on the provider in its turn.
    @Test func aNoteDeletedWhileASyncWalksStaysDeleted() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        let (reached, resume) = store.holdListing(of: "")
        let sync = Task { try await mirror.syncMetadata() }
        await reached.wait()

        await collection.deleteNote(welcome)
        resume.open()
        _ = try await sync.value
        #expect(!FileManager.default.fileExists(atPath: welcome.fileURL.path), "the walk put the deleted note back")
        await sent(collection)
        #expect(mirror.manifest.entries["Welcome.md"] == nil, "the sync put the deleted note back in the record")
        #expect(!FileManager.default.fileExists(atPath: welcome.fileURL.path))
        #expect(store.text(at: "/Welcome.md") == nil, "the note was not deleted on the provider")
    }

    // MARK: - A walk away from the main actor

    /// A one-note listing of the provider's root, as a walk hands it over.
    private func listingOfWelcome(in cache: URL) -> WalkBatch {
        WalkBatch(directory: "", children: [
            TreeChild(url: cache.appending(path: "Welcome.md"), isDirectory: false, isMarkdown: true,
                      size: Self.welcome.utf8.count, isOnlineOnly: true, rev: "r1"),
        ], progress: WalkProgress())
    }

    /// Why a delete is reported before its file goes. A walk that lists a
    /// note whose file is gone, with no change waiting to take it, takes the
    /// download for lost and puts a placeholder back — the repair a damaged
    /// cache needs, and the control here. Reported, the note is passed over.
    /// The walk's batch used to run whole on the main actor, where nothing
    /// could fall between a file going and its delete being reported.
    @Test func aWalkPassesOverANoteWhoseDeleteIsWaiting() async throws {
        let (collection, _, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = cache.appending(path: "Welcome.md")

        try FileManager.default.removeItem(at: welcome)
        var unreported = RemoteMirror.WalkFindings(before: mirror.manifest, cacheRoot: cache, remoteRoot: "",
                                                   waiting: RemoteMirror.WaitingToGo())
        unreported.add(listingOfWelcome(in: cache))
        #expect(FileManager.default.fileExists(atPath: welcome.path), "a walk no longer repairs a lost download")

        try FileManager.default.removeItem(at: welcome)
        let waiting = RemoteMirror.WaitingToGo()
        waiting.replace(with: ["Welcome.md"])
        var reported = RemoteMirror.WalkFindings(before: mirror.manifest, cacheRoot: cache, remoteRoot: "",
                                                 waiting: waiting)
        reported.add(listingOfWelcome(in: cache))
        #expect(!FileManager.default.fileExists(atPath: welcome.path), "the walk put back a note whose delete was waiting")
        #expect(reported.found["Welcome.md"] == nil, "the walk recorded a note whose delete was waiting")
    }

    /// And it is: the mirror removes the file itself, once the delete is
    /// waiting (`sendDelete(of:removing:failed:)`) — so no walk can find the
    /// file gone and the delete unknown — and away from the main actor. A
    /// removal that fails reports nothing: nothing waits, and nothing is
    /// deleted on the provider.
    @Test func aDeleteIsReportedBeforeItsFileGoes() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = cache.appending(path: "Welcome.md")

        let waiting = mirror.waitingToGo
        let seen = Locked<(waiting: Bool, onMainThread: Bool)?>(nil)
        try await mirror.sendDelete(of: welcome, removing: {
            seen.set((waiting.contains("Welcome.md"), Thread.isMainThread))
            try FileManager.default.removeItem(at: welcome)
        }, failed: { _ in })
        #expect(seen.value?.waiting == true, "the file went before its delete was reported")
        #expect(seen.value?.onMainThread == false, "the file was removed on the main thread")
        await sent(collection)
        #expect(store.text(at: "/Welcome.md") == nil)

        let idea = cache.appending(path: "Notes/Idea.md")
        await #expect(throws: CocoaError.self) {
            try await mirror.sendDelete(of: idea, removing: { throw CocoaError(.fileWriteNoPermission) }, failed: { _ in })
        }
        #expect(!mirror.isWaitingToGo("Notes/Idea.md"), "a removal that failed is still waiting to go")
        await sent(collection)
        #expect(store.text(at: "/Notes/Idea.md") != nil, "a note whose removal failed was deleted on the provider")
    }

    /// A walk records what the provider says that the record does not: a note
    /// listed as it was is left out of what the walk hands back, where
    /// applying it was main-actor work for nothing — and one listed at a new
    /// revision is in it, the control.
    @Test func aWalkRecordsOnlyWhatChanged() async throws {
        let (collection, _, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        var findings = RemoteMirror.WalkFindings(before: mirror.manifest, cacheRoot: cache, remoteRoot: "",
                                                 waiting: RemoteMirror.WaitingToGo())

        findings.add(listingOfWelcome(in: cache))
        #expect(findings.found.isEmpty, "a walk recorded a note that had not changed: \(findings.found)")

        findings.add(WalkBatch(directory: "", children: [
            TreeChild(url: cache.appending(path: "Welcome.md"), isDirectory: false, isMarkdown: true,
                      size: Self.welcome.utf8.count, isOnlineOnly: true, rev: "r2"),
        ], progress: WalkProgress()))
        #expect(findings.found["Welcome.md"]?.rev == "r2", "a walk left out a note the provider changed")
    }

    /// A note downloaded while the provider's listing named no revision, met
    /// by the first listing that does — the update that asks Box, Drive and
    /// OneDrive for theirs: still downloaded. Comparing the record's missing
    /// revision with the listing's called every download changed.
    @Test func aDownloadOutlivesTheFirstListingToNameItsRevision() async throws {
        let (collection, _, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        var before = mirror.manifest
        before.entries["Welcome.md"]?.rev = nil
        before.entries["Welcome.md"]?.hydrated = true
        let record = try #require(before.entries["Welcome.md"])
        try Data(Self.welcome.utf8).write(to: cache.appending(path: "Welcome.md"))

        var findings = RemoteMirror.WalkFindings(before: before, cacheRoot: cache, remoteRoot: "",
                                                 waiting: RemoteMirror.WaitingToGo())
        findings.add(WalkBatch(directory: "", children: [
            TreeChild(url: cache.appending(path: "Welcome.md"), isDirectory: false, isMarkdown: true,
                      modified: record.modified ?? .distantPast, size: record.size, isOnlineOnly: true, rev: "r1"),
        ], progress: WalkProgress()))
        #expect(findings.found["Welcome.md"]?.hydrated == true, "the first listing to name a revision made the download a placeholder")
        #expect(findings.found["Welcome.md"]?.rev == "r1", "the record did not take the revision")
    }

    /// A provider whose listing names no revision — Box's and Drive's, and the
    /// demo store's — gave a walk nothing to call a note unchanged by, so every
    /// walk made every download a placeholder again, its bytes left in place:
    /// a note open in an editor had its saves refused, and opening it again,
    /// as the refusal advises, downloaded the provider's copy over what was
    /// typed. The same size and date are the provider's word for it now. The
    /// control: a note changed there is a placeholder again.
    @Test func aDownloadOutlivesAWalkOfAProviderWithoutRevisions() async throws {
        let store = MockRemoteStore(preAuthenticated: true)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hn-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Demo")
        try await mirror.syncMetadata()
        let welcome = cache.appending(path: "Welcome.md")
        let idea = cache.appending(path: "Notes/Idea.md")
        try await mirror.hydrate(localURL: welcome)
        try await mirror.hydrate(localURL: idea)
        let downloaded = text(at: welcome)

        try await store.write(Data("# Idea, changed elsewhere\n".utf8), to: "/Notes/Idea.md")
        try await mirror.syncMetadata()
        #expect(!mirror.isPlaceholder(localURL: welcome), "a walk made an unchanged download a placeholder again")
        #expect(text(at: welcome) == downloaded)
        #expect(mirror.isPlaceholder(localURL: idea), "a walk kept a download the provider has changed since")
    }

    /// The self-test's scratch note, left behind by a delete that failed and
    /// removed by hand, on a cloud collection: the mirror hears of it, so the
    /// provider loses it too and no walk puts an empty one back. It was
    /// removed from the cache alone.
    @Test func theSelfTestsLeftoverIsDeletedOnTheProviderToo() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let made = try #require(await collection.createNote(title: "HelloNotes Self-Test"))
        await sent(collection)
        #expect(store.text(at: "/HelloNotes Self-Test.md") != nil, "the scratch note never reached the provider, so this tests nothing")

        await DiagnosticSelfTest.removeLeftover(made.fileURL, in: collection)
        await sent(collection)
        try await mirror.syncMetadata()
        #expect(store.text(at: "/HelloNotes Self-Test.md") == nil, "the provider kept the self-test's note")
        #expect(!FileManager.default.fileExists(atPath: made.fileURL.path), "a walk put the self-test's note back")
    }

    // MARK: - Found by review

    /// An open begun under a note's old name, its download landing while the
    /// rename's turn is out asking the provider: the bytes were written under
    /// the name the note had left, recorded as its download, and the record —
    /// "downloaded" — moved to the new name, where the file was the empty
    /// placeholder. The note opened empty, and its first save put that over
    /// the provider's copy.
    @Test func aDownloadLandingDuringARenameNeverEmptiesTheNote() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let welcome = try note("Welcome", in: collection)
        let (reached, resume) = store.holdListing(of: "")
        let hello = try #require(await collection.renameNote(welcome, to: "Hello"))
        await reached.wait()                         // the rename's turn, asking the provider

        await collection.hydrateIfNeeded(welcome.fileURL)
        resume.open()
        await sent(collection)
        #expect(!FileManager.default.fileExists(atPath: welcome.fileURL.path),
                "the download was written under the name the note had left")
        #expect(collection.isPlaceholder(at: hello.fileURL) || text(at: hello.fileURL) == Self.welcome,
                "the renamed note is empty and recorded as downloaded")
        await collection.hydrateIfNeeded(hello.fileURL)
        #expect(text(at: hello.fileURL) == Self.welcome)
        #expect(store.text(at: "/Hello.md") == Self.welcome)
    }

    /// Trimming the cache drops downloads back to placeholders: safe for a
    /// copy the provider has, and the loss of a version it never received —
    /// mine, kept here after a conflict, or an edit whose upload failed.
    @Test func trimmingTheCacheNeverEmptiesWhatWasNotSent() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        let idea = try note("Idea", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        await collection.hydrateIfNeeded(idea.fileURL)

        store.put("# Theirs\n", at: "/Welcome.md")          // changed elsewhere
        try save("# Mine\n", to: welcome.fileURL, in: collection)
        await sent(collection)
        #expect(collection.lastError?.contains("also changed") == true, "there was no conflict, so this tests nothing")

        store.isReachable = false
        try save("# Idea, offline\n", to: idea.fileURL, in: collection)
        await sent(collection)
        store.isReachable = true

        await mirror.evictIfNeeded(limit: 0)
        #expect(text(at: welcome.fileURL) == "# Mine\n", "trimming the cache emptied mine, kept after a conflict")
        #expect(text(at: idea.fileURL) == "# Idea, offline\n", "trimming the cache emptied an edit never uploaded")
    }

    /// Made while the provider could not be reached, under a name another
    /// device gave a note meanwhile: the next refresh recorded theirs over
    /// mine as a placeholder — mine's saves refused, its upload skipped, and
    /// the next open downloaded theirs over it, keeping no copy of mine.
    @Test func aNoteMadeOfflineUnderANameMadeElsewhereKeepsBoth() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        store.isReachable = false
        let made = try #require(await collection.createNote(title: "Shared"))
        try save("# Mine\n", to: made.fileURL, in: collection)
        await sent(collection)
        store.isReachable = true
        store.put("# Theirs\n", at: "/Shared.md")

        await collection.refreshFromProvider()
        await sent(collection)
        #expect(!collection.isPlaceholder(at: made.fileURL), "a note made here was taken for the provider's placeholder")
        #expect(text(at: made.fileURL) == "# Mine\n")
        let copies = conflictedCopies(in: cache)
        #expect(copies.count == 1, "theirs was not kept beside mine: \(copies)")
        if let copy = copies.first { #expect(text(at: cache.appending(path: copy)) == "# Theirs\n") }
        await collection.hydrateIfNeeded(made.fileURL)
        #expect(text(at: made.fileURL) == "# Mine\n", "opening it downloaded theirs over mine")
    }

    /// Saved while a sync walks, and changed on another device before the
    /// walk lists it: the walk took the new revision for a reason to make the
    /// note a placeholder again, the save — waiting its turn — was refused as
    /// one, and opening the note as the refusal advised downloaded theirs over
    /// mine. It is a conflict, and both are kept.
    @Test func aNoteSavedWhileASyncWalksAndChangedElsewhereKeepsBoth() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        let (reached, resume) = store.holdListing(of: "")
        let sync = Task { try await mirror.syncMetadata() }
        await reached.wait()

        try save("# Mine\n", to: welcome.fileURL, in: collection)
        store.put("# Theirs\n", at: "/Welcome.md")
        resume.open()
        _ = try await sync.value
        await sent(collection)
        #expect(text(at: welcome.fileURL) == "# Mine\n")
        #expect(!collection.isPlaceholder(at: welcome.fileURL), "the walk made the note being saved a placeholder")
        #expect(collection.lastError?.contains("also changed") == true, "\(collection.lastError ?? "")")
        let copies = conflictedCopies(in: cache)
        #expect(copies.count == 1, "theirs was not kept beside mine: \(copies)")
        await collection.hydrateIfNeeded(welcome.fileURL)
        #expect(text(at: welcome.fileURL) == "# Mine\n", "opening it downloaded theirs over mine")
    }

    /// An edit whose upload failed, then the note changed on another device,
    /// then a sync: it took the provider's new revision for a reason to make
    /// the note a placeholder — before the edit had ever been sent — and the
    /// edit was refused from then on, and downloaded over. It is a conflict,
    /// found when the edit goes up, and both are kept.
    @Test func anEditWhoseUploadFailedSurvivesTheNextSync() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        let welcome = try note("Welcome", in: collection)
        await collection.hydrateIfNeeded(welcome.fileURL)
        store.isReachable = false
        try save("# Mine\n", to: welcome.fileURL, in: collection)
        await sent(collection)
        store.isReachable = true
        store.put("# Theirs\n", at: "/Welcome.md")

        try await mirror.syncMetadata()
        #expect(!collection.isPlaceholder(at: welcome.fileURL), "the sync made an edit never sent a placeholder")
        #expect(text(at: welcome.fileURL) == "# Mine\n")
        await collection.refreshFromProvider()
        await sent(collection)
        #expect(collection.lastError?.contains("also changed") == true, "\(collection.lastError ?? "")")
        #expect(conflictedCopies(in: cache).count == 1, "theirs was not kept beside mine")
        await collection.hydrateIfNeeded(welcome.fileURL)
        #expect(text(at: welcome.fileURL) == "# Mine\n", "opening it downloaded theirs over mine")
    }

    /// A collection added before a note made here could go up by itself: its
    /// manifest has a delta cursor — taken at the end of a complete walk — and
    /// no record of the walk's completion, and every refresh goes through the
    /// delta. What was made offline never went up.
    @Test func aCollectionFromBeforeSendsWhatWasMadeOffline() async throws {
        let store = StrictFolderStore()
        let (collection, _, cache) = try await cloudCollection(store)
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = try #require(collection.remote)
        var older = mirror.manifest
        older.lastCompleteSync = nil
        older.deltaCursor = "c0"
        mirror.manifest = older
        store.deltaFeed = true

        store.isReachable = false
        let made = try #require(await collection.createNote(title: "Offline"))
        try save("# Offline\n", to: made.fileURL, in: collection)
        await sent(collection)
        store.isReachable = true

        await collection.refreshFromProvider()
        await sent(collection)
        #expect(store.text(at: "/Offline.md") == "# Offline\n", "a note made offline stayed on this device")
    }

    /// A rename the provider refuses — the name taken there by a note this
    /// device has not seen — leaves the note renamed here and where it was
    /// there. It stays the note: still a placeholder, opening from where the
    /// provider has it, never a new, empty one (which the next refresh would
    /// have uploaded); a sync sees the other note at that name without taking
    /// it for this one; and a refresh asks for the move again, which goes
    /// through once the name is free.
    @Test func aRenameTheProviderRefusesKeepsTheNote() async throws {
        let (collection, store, cache) = try await cloudCollection()
        defer { try? FileManager.default.removeItem(at: cache) }
        store.put("# Someone else's\n", at: "/Hello.md")
        let welcome = try note("Welcome", in: collection)

        let hello = try #require(await collection.renameNote(welcome, to: "Hello"))
        await sent(collection)
        #expect(collection.lastError?.contains("already has something named") == true, "\(collection.lastError ?? "")")
        #expect(collection.isPlaceholder(at: hello.fileURL), "the renamed stand-in was taken for a new, empty note")

        await collection.refreshFromProvider()
        await sent(collection)
        await collection.hydrateIfNeeded(hello.fileURL)
        #expect(text(at: hello.fileURL) == Self.welcome, "the renamed note opened as the other note of that name")
        #expect(store.text(at: "/Hello.md") == "# Someone else's\n", "the other note of that name was written over")
        #expect(store.text(at: "/Welcome.md") == Self.welcome)

        try await store.delete(path: "/Hello.md")
        await collection.refreshFromProvider()
        await sent(collection)
        #expect(store.text(at: "/Hello.md") == Self.welcome, "the move was never asked for again")
        #expect(store.text(at: "/Welcome.md") == nil)
    }

    /// Adding a cloud folder that is already open made a second mirror of the
    /// same cache, each with its own record and its own turns.
    @Test func aCacheHasOneMirror() {
        let store = StrictFolderStore()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hn-cloud-\(UUID().uuidString)")
        let first = RemoteMirror.open(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Test cloud")
        let second = RemoteMirror.open(store: store, cacheRoot: cache, remoteRoot: "", displayName: "Test cloud")
        #expect(first === second, "a second mirror was made of a cache already open")
    }

    /// Every provider's date shape: Dropbox's and Box's without fractional
    /// seconds (Box with an offset), Drive's with milliseconds, Graph's with
    /// up to seven digits — which the plain formatter could not read at all.
    @Test func providerDatesAreReadInEveryShape() {
        let seconds: [(String, TimeInterval)] = [
            ("2015-05-12T15:50:38Z", 1_431_445_838),
            ("2012-12-12T10:53:43-08:00", 1_355_338_423),
            ("2016-09-19T20:06:45.123Z", 1_474_315_605.123),
            ("2017-11-27T21:31:12.1234567Z", 1_511_818_272.1234567),
        ]
        for (text, expected) in seconds {
            let date = RemoteDate.parse(text)
            #expect(date.map { abs($0.timeIntervalSince1970 - expected) < 0.001 } == true, "\(text) read as \(String(describing: date))")
        }
        #expect(RemoteDate.parse("yesterday") == nil)
    }

    // MARK: - The main actor

    /// Every change a cloud collection makes records itself in the manifest,
    /// and the manifest was encoded and written whole on the main actor each
    /// time — 22 ms at 10,000 entries, measured by the concurrency review. The
    /// record is kept in memory there, and written elsewhere.
    @Test func recordingAChangeDoesNotWriteTheManifestOnTheMainActor() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("hn-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let mirror = RemoteMirror(store: StrictFolderStore(), cacheRoot: cache, remoteRoot: "", displayName: "Test cloud")
        var large = mirror.manifest
        for index in 0..<10_000 {
            large.entries["Folder \(index / 100)/Note \(index).md"] = RemoteManifest.Entry(
                remotePath: "/Folder \(index / 100)/Note \(index).md", size: 1_000,
                modified: Date(), rev: "r\(index)", hydrated: index % 3 == 0)
        }
        mirror.manifest = large                              // warm
        var times: [Duration] = []
        for index in 0..<5 {
            large.entries["Note \(index).md"] = RemoteManifest.Entry(remotePath: "/Note \(index).md")
            let clock = ContinuousClock()
            let start = clock.now
            mirror.manifest = large
            times.append(clock.now - start)
        }
        let median = times.sorted()[times.count / 2]
        #expect(median < .milliseconds(3), "recording a change held the main actor \(median)")
        // Written all the same: the last record is the one on disk.
        let onDisk = try #require(RemoteManifest.load(fromCacheRoot: cache))
        #expect(onDisk.entries.count == large.entries.count)
        #expect(onDisk.entries["Note 4.md"] != nil, "the newest record never reached the disk")
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

// MARK: - A provider as strict as Box and Google Drive

/// An in-memory provider that puts a file only into a folder that exists (Box
/// and Google Drive need the parent's id; Dropbox and OneDrive make the
/// folders on the way), refuses to move or make over something already there,
/// issues a new revision per write, can be unreachable, and can hold a listing
/// so a test can act while a sync is part-way through a walk.
final class StrictFolderStore: RemoteStore, @unchecked Sendable {
    let providerName = "Test cloud"
    let accountID = "test"
    var isAuthenticated: Bool { true }
    func authenticate() async throws {}
    func signOut() {}

    private let lock = NSLock()
    private var files: [String: (data: Data, rev: Int)] = [
        "/Welcome.md": (Data("# Welcome\n\nFrom the provider.\n".utf8), 1),
        "/Notes/Idea.md": (Data("# Idea\n".utf8), 1),
    ]
    private var folders: Set<String> = ["/Notes"]
    private var nextRev = 2
    private var readCount = 0
    private var reachable = true
    private var holds: [String: (reached: Gate, resume: Gate)] = [:]
    private var readHolds: [String: (reached: Gate, resume: Gate)] = [:]
    private var feed = false
    private var cursorNumber = 0

    /// A delta feed that reports nothing changed, with a new cursor each time —
    /// enough for a refresh to take the delta path rather than a walk.
    var deltaFeed: Bool {
        get { locked { feed } }
        set { locked { feed = newValue } }
    }

    func changes(since cursor: String?, path: String) async throws -> RemoteChangeSet? {
        try locked {
            guard feed else { return nil }
            try reachableOrThrow()
            cursorNumber += 1
            return RemoteChangeSet(changed: [], deleted: [], cursor: "c\(cursorNumber)")
        }
    }

    var isReachable: Bool {
        get { locked { reachable } }
        set { locked { reachable = newValue } }
    }
    var reads: Int { locked { readCount } }
    var paths: [String] { locked { Array(files.keys) } }

    // MARK: Test side

    /// As another device would: the folders made on the way.
    func put(_ text: String, at path: String) {
        locked {
            var parent = Self.parent(of: path)
            while !parent.isEmpty { folders.insert(parent); parent = Self.parent(of: parent) }
            files[path] = (Data(text.utf8), nextRev)
            nextRev += 1
        }
    }

    func text(at path: String) -> String? {
        locked { files[path].map { String(decoding: $0.data, as: UTF8.self) } }
    }

    func hasFolder(_ path: String) -> Bool { locked { folders.contains(path) } }

    /// The next listing of `path` opens `reached` and waits for `resume`.
    func holdListing(of path: String) -> (reached: Gate, resume: Gate) {
        let hold = (reached: Gate(), resume: Gate())
        locked { holds[path] = hold }
        return hold
    }

    /// The next read of `path` takes the file's bytes, then opens `reached`
    /// and waits for `resume` — a download on its way, holding what the
    /// provider had when it began.
    func holdRead(of path: String) -> (reached: Gate, resume: Gate) {
        let hold = (reached: Gate(), resume: Gate())
        locked { readHolds[path] = hold }
        return hold
    }

    // MARK: RemoteStore

    func list(path: String) async throws -> [RemoteEntry] {
        let p = DropboxPath.normalize(path)
        if let hold = locked({ holds.removeValue(forKey: p) }) {
            hold.reached.open()
            await hold.resume.wait()
        }
        return try locked {
            try reachableOrThrow()
            guard p.isEmpty || folders.contains(p) else { throw RemoteStoreError.http(404, "not_found") }
            let subfolders = folders.filter { Self.parent(of: $0) == p }.map {
                RemoteEntry(path: $0, name: Self.name($0), isDirectory: true, size: 0, modified: nil, rev: nil)
            }
            let notes = files.filter { Self.parent(of: $0.key) == p }.map {
                RemoteEntry(path: $0.key, name: Self.name($0.key), isDirectory: false,
                            size: $0.value.data.count, modified: nil, rev: "r\($0.value.rev)")
            }
            return subfolders + notes
        }
    }

    func read(path: String) async throws -> Data {
        let (data, hold) = try locked { () -> (Data, (reached: Gate, resume: Gate)?) in
            try reachableOrThrow()
            guard let file = files[path] else { throw RemoteStoreError.http(404, "not_found") }
            readCount += 1
            return (file.data, readHolds.removeValue(forKey: path))
        }
        if let hold {
            hold.reached.open()
            await hold.resume.wait()
        }
        return data
    }

    func write(_ data: Data, to path: String) async throws {
        try locked {
            try reachableOrThrow()
            let parent = Self.parent(of: path)
            guard parent.isEmpty || folders.contains(parent) else {
                throw RemoteStoreError.http(404, "No folder \(parent)")
            }
            guard !folders.contains(path) else { throw RemoteStoreError.http(409, "a folder is there") }
            files[path] = (data, nextRev)
            nextRev += 1
        }
    }

    func delete(path: String) async throws {
        try locked {
            try reachableOrThrow()
            if files.removeValue(forKey: path) != nil { return }
            guard folders.contains(path) else { throw RemoteStoreError.http(404, "not_found") }
            folders = folders.filter { $0 != path && !$0.hasPrefix(path + "/") }
            files = files.filter { !$0.key.hasPrefix(path + "/") }
        }
    }

    func move(from source: String, to destination: String) async throws {
        try locked {
            try reachableOrThrow()
            let parent = Self.parent(of: destination)
            guard parent.isEmpty || folders.contains(parent) else { throw RemoteStoreError.http(404, "No folder \(parent)") }
            guard files[destination] == nil, !folders.contains(destination) else {
                throw RemoteStoreError.http(409, "Something is already at \(destination)")
            }
            if let file = files.removeValue(forKey: source) {
                files[destination] = file
                return
            }
            guard folders.contains(source) else { throw RemoteStoreError.http(404, "not_found") }
            folders = Set(folders.map { $0 == source || $0.hasPrefix(source + "/")
                ? destination + $0.dropFirst(source.count) : $0 })
            files = Dictionary(uniqueKeysWithValues: files.map { key, value in
                (key.hasPrefix(source + "/") ? destination + key.dropFirst(source.count) : key, value)
            })
        }
    }

    func createFolder(path: String) async throws {
        try locked {
            try reachableOrThrow()
            let parent = Self.parent(of: path)
            guard parent.isEmpty || folders.contains(parent) else { throw RemoteStoreError.http(404, "No folder \(parent)") }
            guard files[path] == nil, !folders.contains(path) else {
                throw RemoteStoreError.http(409, "Something is already at \(path)")
            }
            folders.insert(path)
        }
    }

    // MARK: Helpers

    private func reachableOrThrow() throws {
        guard reachable else { throw URLError(.notConnectedToInternet) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    private static func name(_ path: String) -> String {
        String(path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...])
    }
}

/// Opens once; everything waiting on it — before or after — goes on.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiting
        waiting = []
        lock.unlock()
        for continuation in resumed { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }
}

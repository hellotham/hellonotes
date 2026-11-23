//
//  CollectionEmbedProvider.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import MarkdownCore     // PictureNames
import MarkdownEditor   // PlatformImage

/// Renders `![[Note]]` / `![[Note#heading]]` transclusions to images — the
/// target note's Markdown rendered to a titled card via ``NoteTranscluder`` —
/// and finds the picture an `![[photo.png]]` names among the collection's
/// pictures (`pictureURL`), which Edit and Preview each draw themselves.
///
/// Reads the target note lazily on `image(forName:isDark:)` and caches by
/// content (keyed on a cheap mtime `stat` + appearance) so repeat renders are
/// free. Cross-platform.
///
/// **`nonisolated`, and `@unchecked Sendable` because of `lock`**, which
/// guards `notesByName` and `cache`: `update(notes:)` is called on the main
/// actor and `image(forName:isDark:)` from wherever a card is wanted — Edit's
/// renderer on the main actor, Preview's page on the pool. Unannotated, the
/// class was main-actor in this target, so the lock guarded nothing and
/// Preview's every card hopped to the main actor (implemented.md §51.36).
nonisolated final class CollectionEmbedProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var notesByName: [String: URL] = [:]   // lowercased title → file URL
    private var cache = BoundedCache<String, PlatformImage>(limit: 64)

    /// The collection whose notes this draws — set by the collection. A
    /// provider of a view's own has none.
    @MainActor weak var owner: Collection?

    /// Moves when what a card shows may have: a note saved, a rebuild landed,
    /// the note set changed — the owner's `derivedRevision`, read through, so
    /// a view that reads this in its body is redrawn when that moves.
    ///
    /// Preview was handed the revision beside the provider, as
    /// `collection?.derivedRevision ?? 0`, by a pane the main window gives no
    /// collection — so it was always 0 there, and a card redrew only when the
    /// open note itself changed (implemented.md §51.36). Coming with the
    /// cards, it goes wherever they go.
    @MainActor var revision: Int { owner?.derivedRevision ?? 0 }

    /// Refresh the name→URL map. Cached cards are keyed by the target's path +
    /// mtime + appearance, so an edited transclusion re-renders on its own once
    /// its file's mtime advances — no explicit invalidation needed here.
    func update(notes: [Note]) {
        lock.lock(); defer { lock.unlock() }
        // **Indexed by every trailing path a `![[target]]` might name, not by
        // title alone.**
        //
        // Wiki-link *navigation* resolves through `linkGraph`, which handles
        // aliases and relative paths — `WikiLinkNavigation.resolve` says so in
        // as many words. Transclusion had its own map keyed only on the title,
        // so the two resolvers disagreed about what a target meant:
        // `[[Examples/Nested Note]]` opened the note and
        // `![[Examples/Nested Note]]` rendered nothing at all. The shipped tour
        // uses the second form, so the one note in `DefaultCollection` that
        // demonstrates transclusion demonstrated it not working — on both
        // platforms, for anyone who opened it.
        //
        // Suffixes rather than a root-relative path, because this object is not
        // told the collection root and does not need to be: "Nested Note",
        // "Examples/Nested Note" and any deeper qualification all land on the
        // same file, and a title still wins a tie because it is inserted first.
        var map: [String: URL] = [:]
        for note in notes {
            let key = note.title.lowercased()
            if map[key] == nil { map[key] = note.fileURL }
        }
        for note in notes {
            for key in Self.pathKeys(for: note.fileURL) where map[key] == nil {
                map[key] = note.fileURL
            }
        }
        notesByName = map
    }

    /// The note a target names, or nil. Exposed so the resolver can be tested
    /// without rendering an image — the drawing needs a graphics context and
    /// the lookup is the part that was wrong.
    func url(forName name: String) -> URL? {
        let base = name.split(separator: "#", maxSplits: 1).first.map(String.init) ?? name
        lock.lock(); defer { lock.unlock() }
        return notesByName[base.lowercased()]
    }

    /// "Nested Note", "Examples/Nested Note", … — each trailing run of path
    /// components, extension dropped, lowercased.
    ///
    /// One definition, in `MarkdownParsing`, because `LinkGraph` needs the same
    /// answer: a target that transcludes must also be a link, and for a while
    /// `![[Manual/Collections]]` rendered a card while `[[Manual/Collections]]`
    /// counted as broken. Kept here as a name so the existing tests still read.
    static func pathKeys(for url: URL) -> [String] { MarkdownParsing.pathKeys(for: url) }

    /// A rendered transclusion card for an `![[Note]]` target, or nil when the
    /// target isn't a note in this collection.
    ///
    /// **`async`, and the file work happens off the main actor.** This used to
    /// be a synchronous `@MainActor` method that did a `stat` and a
    /// *coordinated read* inline — once per `![[transclusion]]` the editor laid
    /// out. Against a File Provider both of those are blocking XPC calls, so a
    /// note with a handful of transclusions could stall typing for as long as
    /// iCloud felt like taking. Only the drawing needs the main actor (it uses
    /// the platform graphics context), so only the drawing stays there.
    ///
    /// The caller (`BlockRenderAdapter.renderTransclusion`) already awaits, so
    /// this costs no extra machinery — no placeholder, no invalidation pass.
    func image(forName name: String, isDark: Bool) async -> PlatformImage? {
        let (base, heading) = splitHeading(name)

        // `withLock`, not `lock()` and `unlock()`: this is an `async` function,
        // where a suspension between the two would hold the lock across it —
        // Swift 6 refuses the pair here, and this target could only warn.
        let url = lock.withLock { notesByName[base.lowercased()] }
        guard let url else { return nil }   // not a note → no transclusion

        // **The note's date first, and its text only for a card not drawn.**
        // A card already drawn at this date is the card; the note was read
        // whole on every call, hit or miss — at each pause in typing in Edit
        // and each page in Preview.
        let key = await offMain { () -> String in
            // As the file is now: a stored URL answers from its first look,
            // off the main run loop (`FileIO.currentResourceValues`, §51.56).
            let mtime = (try? FileIO.currentResourceValues(at: url, keys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return "\(isDark ? "d" : "l")\u{1}\(url.path)\u{1}\(heading ?? "")\u{1}\(mtime)"
        }
        if let cached = lock.withLock({ cache[key] }) { return cached }

        // Read and sectioned off the main actor; only the drawing needs it.
        // Waited for first if it is online-only, with the deadline a download
        // has anywhere: a coordinated read downloads inside the read, and held
        // its lane for as long as that took (implemented.md §51.64).
        guard await FileIO.waitForDownload(at: url, using: .scans) == .arrived else { return nil }
        let sectioned = await FileIO.onScanLane(for: url) { () -> String? in
            guard let markdown = try? FileIO.readString(at: url) else { return nil }
            return NoteTranscluder.section(heading, from: markdown)
        }
        guard let sectioned else { return nil }
        let title = heading.map { "\(base) › \($0)" } ?? base
        guard let image = await MainActor.run(body: {
            NoteTranscluder.image(markdown: sectioned, title: title, isDark: isDark)
        }) else { return nil }

        // Keys are date-versioned, so an edited note's old cards would pile
        // up: the cache keeps 64, letting go of the one used longest ago. It
        // was emptied outright past 64, and the next page drew every card again.
        lock.withLock { cache[key] = image }
        return image
    }

    // MARK: - Pictures

    /// The pictures the collection holds, by place (`PictureIndex`); its
    /// folder and that folder's spellings, to find a note's place by; and
    /// whether a walk has listed the folder since the collection opened. A
    /// provider of a view's own has no collection, no folder and no list,
    /// and never waits for one. All guarded by `lock`.
    private var pictures = PictureIndex()
    private var pictureRoot: URL?
    private var pictureRootSpellings: [String] = []
    private var picturesListed = false
    private var waitingForPictures: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// The collection this provider draws for will list its pictures: its
    /// folder, and every spelling of it (`Collection.rootSpellings`).
    func listsPictures(in root: URL, spellings: [String]) {
        lock.withLock {
            pictureRoot = root
            pictureRootSpellings = spellings
        }
    }

    /// Where the index is made: off the main actor, and in the order it was
    /// asked for, so `picturesAreListed` — queued here too — says so only
    /// once the walk's pictures are in it. Made on the main actor, at every
    /// change to the collection's files, it cost two to three microseconds a
    /// picture: tens of milliseconds a change in a vault of ten thousand.
    private let indexing = DispatchQueue(label: "com.hellotham.HelloNotes.picture-index", qos: .userInitiated)
    /// The newest list handed over; an older one still queued is not made.
    private var newestPictures = 0

    /// The collection's other files, as a walk or a change to them left them:
    /// the pictures among them — what `PictureNames` calls one, which is what
    /// Edit and Preview draw — by their places in the collection, made into
    /// the index off the main actor (`indexing`).
    func update(pictures files: [CollectionFile]) {
        let asked = lock.withLock { () -> Int in
            newestPictures += 1
            return newestPictures
        }
        indexing.async { [self] in
            let spellings = lock.withLock { asked == newestPictures ? pictureRootSpellings : nil }
            guard let spellings else { return }
            let index = PictureIndex(places: files.compactMap {
                PictureNames.isPicture($0.url.lastPathComponent)
                    ? Collection.place(of: $0.url.path, in: spellings) : nil
            })
            lock.withLock { if asked == newestPictures { pictures = index } }
        }
    }

    /// A walk has listed the folder — or the folder cannot be read, or the
    /// collection has closed: what is listed now is all a wait will get.
    /// Behind any list still being made (`indexing`), so a lookup it wakes
    /// finds what the walk found.
    func picturesAreListed() {
        indexing.async { [self] in
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                picturesListed = true
                defer { waitingForPictures.removeAll() }
                return Array(waitingForPictures.values)
            }
            for continuation in waiting { continuation.resume() }
        }
    }

    /// The file the picture `embed` names, seen from `note`, or nil.
    ///
    /// Among the collection's pictures first (`PictureIndex`): no disk, and
    /// the only way to find `![[photo.png]]` in a folder the note does not
    /// name. Then the paths it can name on the disk — from the note's folder,
    /// from the collection's, the note's own pictures folder — for a
    /// collection that does not list its other files (Show Non-Note Files
    /// off), a folder the walk does not enter (`.attachments`), and a note
    /// in no collection at all. Then, if the collection has not yet listed
    /// its folder — a note opened at launch is drawn from the index cache
    /// before the walk that lists pictures has run — and `waitForList`,
    /// once it has. Edit waits: its picture is drawn when it lands. Preview
    /// does not: its page is drawn again when the walk's rebuild moves
    /// `revision`.
    ///
    /// `@concurrent`: the disk is asked, and the caller may be anywhere.
    @concurrent func pictureURL(for embed: PictureEmbed, from note: URL,
                                attachmentFolder: String, waitForList: Bool) async -> URL? {
        let folder = note.deletingLastPathComponent()
        func listed() -> URL? {
            let (index, root, spellings) = lock.withLock { (pictures, pictureRoot, pictureRootSpellings) }
            guard let root, !index.isEmpty,
                  let notePlace = Collection.place(of: folder.path, in: spellings),
                  let place = index.place(of: embed, fromNoteIn: notePlace, attachmentFolder: attachmentFolder)
            else { return nil }
            return root.appending(path: place, directoryHint: .notDirectory)
        }
        // The lists handed over so far, in the index: a walk's lands off the
        // main actor (`indexing`), and Preview's page, drawn again as the walk
        // ends, would otherwise look before it was there — and say the
        // picture in words until something else drew the page again.
        await indexed()
        if let found = listed() { return found }
        if let found = await onDisk(embed, from: folder, attachmentFolder: attachmentFolder) { return found }
        guard waitForList, embed.byName else { return nil }
        let expectsList = lock.withLock { pictureRoot != nil && !picturesListed }
        // Listed since the first look — the walk landed while the disk was
        // asked — so the list is looked at again, not given up on: the index
        // is always updated before the folder is said to be listed.
        guard expectsList else { return listed() }
        await waitForPictures()
        return listed()
    }

    /// The paths `embed` can name, looked for on the disk — each asked on
    /// the scans' lanes (`FileIO.onScanLane`), where the picture found is
    /// read (`FileIO.embeddedData`). A folder a provider has not brought
    /// down, or a share that has stopped answering, answers when it pleases,
    /// and asked on the concurrency pool each embed on a page held one of its
    /// few threads for as long. Worked out by text — `URL.standardized`,
    /// which asks nothing, never `standardizedFileURL`, which asks the disk
    /// whether a path spelled `/private/…` has a shorter name.
    private func onDisk(_ embed: PictureEmbed, from folder: URL, attachmentFolder: String) async -> URL? {
        let written = embed.path
        guard !written.isEmpty else { return nil }
        let (root, spellings) = lock.withLock { (pictureRoot, pictureRootSpellings) }
        var tries: [URL] = []
        if written.hasPrefix("/") {
            if let root { tries.append(root.appending(path: String(written.drop(while: { $0 == "/" })))) }
        } else {
            tries.append(folder.appending(path: written))
            if embed.byName {
                if let root { tries.append(root.appending(path: written)) }
                let sub = attachmentFolder.trimmingCharacters(in: .whitespaces)
                if !sub.isEmpty { tries.append(folder.appending(path: sub).appending(path: written)) }
            }
        }
        for candidate in tries.map(\.standardized) {
            // An Obsidian embed names a picture in its vault: `../` climbs no
            // further than the collection's folder. By text, against its
            // spellings (`Collection.place(of:in:)`).
            if embed.byName, root != nil, Collection.place(of: candidate.path, in: spellings) == nil { continue }
            if await FileIO.onScanLane(for: candidate, { Self.isFile(candidate) }) { return candidate }
        }
        return nil
    }

    /// Whether a file is at `url`, as the folder is now
    /// (`FileIO.currentResourceValues`) — a file in the cloud not yet
    /// downloaded is a file — and through a symbolic link, as `fileExists`
    /// answered: a link's own resource values say it is not a regular file.
    private static func isFile(_ url: URL) -> Bool {
        guard let values = try? FileIO.currentResourceValues(at: url, keys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        if values.isRegularFile == true { return true }
        guard values.isSymbolicLink == true else { return false }
        return (try? FileIO.currentResourceValues(at: url.resolvingSymlinksInPath(),
                                                  keys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Until every list handed over before now is in the index (`indexing`,
    /// which is serial). One hop when nothing is being made.
    private func indexed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            indexing.async { continuation.resume() }
        }
    }

    /// How many lookups are waiting for the collection to list its folder —
    /// for a test to wait on, rather than for a time it hopes is long enough.
    var lookupsWaitingForPictures: Int { lock.withLock { waitingForPictures.count } }

    /// Until the collection says its folder is listed, or this task is
    /// cancelled — a note closed while it waited.
    private func waitForPictures() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if picturesListed || Task.isCancelled { return true }
                    waitingForPictures[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waitingForPictures.removeValue(forKey: id) }?.resume()
        }
    }

    private func splitHeading(_ name: String) -> (base: String, heading: String?) {
        guard let hash = name.firstIndex(of: "#") else { return (name, nil) }
        let base = String(name[..<hash])
        let heading = String(name[name.index(after: hash)...])
        return (base, heading.isEmpty ? nil : heading)
    }
}

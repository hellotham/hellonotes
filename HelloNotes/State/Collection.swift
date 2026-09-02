//
//  Collection.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// Where a collection stands with the folder it points at.
///
/// The distinction that matters is **empty versus unreadable**. Until this
/// existed they looked identical on screen — a vault on an unplugged drive and a
/// vault you had emptied both showed no notes — and they mean opposite things.
/// A collection that cannot be read now says so and *keeps its last known
/// contents*: nothing derived is discarded on the strength of a failed look.
enum CollectionState: Equatable {
    case ready
    /// The index may be missing changes and a full rescan is owed. Anything
    /// reading the index (search above all) must say its answers are partial.
    case stale(StaleReason)
    case unavailable(UnavailableReason)

    enum StaleReason: Equatable {
        /// FSEvents dropped events; the change list is incomplete by its own
        /// admission, so only a full rescan can be trusted.
        case eventsDropped
        /// A scan was interrupted — cancelled, suspended, or blocked by a folder
        /// it couldn't read — so the note list is a subset of the folder.
        case scanIncomplete
    }

    enum UnavailableReason: Equatable {
        case missing            // moved, renamed, or deleted
        case unmounted          // the volume went away
        case permissionDenied   // the sandbox grant no longer holds

        var explanation: String {
            switch self {
            case .missing:          return "This folder has been moved, renamed, or deleted."
            case .unmounted:        return "The disk holding this folder isn’t connected."
            case .permissionDenied: return "HelloNotes no longer has permission to read this folder."
            }
        }
    }
}

/// One open collection: a local directory (the absolute source of truth) plus
/// everything derived from it — its notes, attachments, `[[wiki-link]]` graph,
/// search index, and its own Git repository and bookmarks. Collections are
/// isolated: links, backlinks and the graph resolve only within a collection.
/// A `Library` holds several collections open at once.
@MainActor
@Observable
final class Collection: Identifiable {
    /// Stable identity — the standardized root path (survives re-indexing and
    /// dedupes a folder opened twice).
    nonisolated let id: String

    /// The folder this collection indexes.
    let rootURL: URL

    /// Non-nil when this collection is a cloud account reached over a provider's
    /// API (Phase 4): `rootURL` is then a local *mirror* of the remote folder,
    /// and saved edits are uploaded back through the mirror. `nil` = an ordinary
    /// local/File-Provider folder.
    var remote: RemoteMirror?
    var isRemote: Bool { remote != nil }

    /// The security-scoped bookmark this collection was opened from, kept so it
    /// can be re-resolved when the folder goes missing (a bookmark follows a
    /// *moved* folder, which a path cannot) and re-minted when it goes stale.
    var bookmarkData: Data?

    /// The collection's display name (the remote folder name, or its folder name).
    var name: String { remote?.displayName ?? rootURL.lastPathComponent }

    /// Whether the folder is readable, and whether what we show is complete.
    /// Only ever set through the helpers below, which are careful never to
    /// discard `notes`, `attachments`, `folders` or the index cache.
    private(set) var state: CollectionState = .ready

    var isAvailable: Bool {
        if case .unavailable = state { return false } else { return true }
    }

    /// True while the index is known to be behind the folder. Callers that
    /// present derived answers — search most of all — must disclose this rather
    /// than serve a confident subset.
    var hasIncompleteIndex: Bool {
        if case .stale = state { return true } else { return false }
    }

    /// Whether non-Markdown files are collected at all.
    ///
    /// Gates the **walk**, not the display. On a cloud folder holding a hundred
    /// thousand documents, filtering them out afterwards would still have meant
    /// reading every name; not collecting them is the entire point. Per
    /// collection, because a mixed Box root and a clean notes vault want
    /// different answers — and persisted, because re-deciding it every launch
    /// would be its own small annoyance.
    var showsNonNoteFiles: Bool {
        didSet {
            guard showsNonNoteFiles != oldValue else { return }
            UserDefaults.standard.set(showsNonNoteFiles, forKey: Self.showFilesKey(id))
            // The answer changes what the walk collects, so it has to walk again.
            Task { await scanOffMain(); refreshDerived() }
        }
    }

    nonisolated static func showFilesKey(_ id: String) -> String {
        "showsNonNoteFiles:" + id
    }

    /// How many non-note files the last scan passed over. Stated rather than
    /// merely hidden — an invisible omission is how someone concludes their PDFs
    /// never imported.
    private(set) var hiddenFileCount = 0

    /// Live counts while a scan is running, `nil` when idle.
    private(set) var scanProgress: WalkProgress?

    /// Whether the scan has been running long enough to be worth mentioning.
    /// A vault that scans in 80 ms must look exactly as it did before any of
    /// this existed — a progress bar that flashes is worse than none.
    private(set) var showsScanProgress = false

    private var currentScan: Task<WalkResult, Never>?

    /// Stop the running scan. Whatever it found is kept, and the checkpoint it
    /// leaves means resuming picks up where it stopped rather than starting over.
    func cancelScan() { currentScan?.cancel() }

    /// Mark the folder unreadable **without touching anything derived from it**.
    /// The last good picture stays on screen, read-only, so a drive unplugged
    /// for a minute doesn't cost the user their notes list and index.
    func markUnavailable(_ reason: CollectionState.UnavailableReason) {
        guard state != .unavailable(reason) else { return }
        state = .unavailable(reason)
    }

    /// Record that the index is behind the folder. Never overrides
    /// unavailability: not being able to read the folder is the bigger news.
    func markStale(_ reason: CollectionState.StaleReason) {
        if case .unavailable = state { return }
        state = .stale(reason)
    }

    /// Re-check a folder that went away, and pick it back up if it is there.
    /// Returns whether the collection is now readable.
    @discardableResult
    func recheckAvailability() async -> Bool {
        guard case .unavailable = state else { return true }
        guard Self.unavailability(of: rootURL) == nil else { return false }
        state = .ready
        await scanOffMain()
        refreshDerived()
        return true
    }

    /// Why the folder can't be read, or `nil` when it can.
    ///
    /// `fileExists` alone answers the wrong question for a revoked sandbox
    /// grant, where the path is present and the read is refused — so this
    /// actually attempts the enumeration the scan is about to do.
    nonisolated static func unavailability(of url: URL) -> CollectionState.UnavailableReason? {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else {
            return .permissionDenied
        }
        return nil
    }

    /// The Markdown notes discovered inside the collection.
    var notes: [Note] = []

    /// Non-Markdown files (PDFs, images, CSVs, …), browsable alongside notes.
    var attachments: [CollectionFile] = []

    /// Every directory inside the collection, so empty folders (e.g. one just
    /// created, or one whose last note moved out) still appear in the tree.
    var folders: [URL] = []

    /// Bumped on every `scan()` — a cheap fingerprint of the note/attachment/
    /// folder *set* so views can cache the folder tree and rebuild only when the
    /// structure actually changes, instead of re-deriving it every render.
    private(set) var revision = 0

    /// Bumped whenever the content-derived index (link graph, search) changes,
    /// so views can recompute derived data (e.g. the references panel) only when
    /// it actually changed rather than on every render.
    private(set) var derivedRevision = 0

    // MARK: Relatedness

    /// "Which other notes is this about the same things as?" — see
    /// `Core/RelatednessIndex.swift` and `docs/semantic-retrieval-benchmark.md`.
    ///
    /// Built **on first use, not on launch**. Building reads every note once,
    /// which on the measured 2,027-note iCloud vault is ~12 seconds of
    /// coordinated I/O — an unacceptable launch tax for a feature a given
    /// session may never touch. It is pure derived data, so building late costs
    /// nothing but the first call.
    private var relatedness: TermVectorRelatednessIndex?
    private var relatednessBuild: Task<TermVectorRelatednessIndex, Never>?

    /// Whether the index is already built, so UI can offer "Suggest" without
    /// implying it is instant.
    var hasRelatednessIndex: Bool { relatedness != nil }

    /// The `limit` notes most related to `text`. Builds the index on first call.
    func relatedNotes(to text: String, excluding: URL?, limit: Int = 10) async -> [RelatedNote] {
        let index = await relatednessIndex()
        return await index.related(to: text, excluding: excluding, limit: limit)
    }

    /// The index, building it if necessary.
    ///
    /// The in-flight `Task` is held so that two callers arriving together — the
    /// References tab and a menu command, say — share one build instead of
    /// reading the whole vault twice.
    private func relatednessIndex() async -> TermVectorRelatednessIndex {
        if let relatedness { return relatedness }
        if let relatednessBuild { return await relatednessBuild.value }

        let notes = self.notes
        let build = Task.detached(priority: .userInitiated) { () -> TermVectorRelatednessIndex in
            // Reading and preparing happens off the main actor; so does the
            // tokenising inside `rebuild`, because the index is an actor.
            let documents: [RelatednessDocument] = notes.compactMap { note in
                guard let raw = try? FileIO.readString(at: note.fileURL) else { return nil }
                let text = RetrievalText.prepare(raw)
                guard text.count >= 80 else { return nil }
                return RelatednessDocument(url: note.fileURL, title: note.title, text: text)
            }
            let index = TermVectorRelatednessIndex()
            await index.rebuild(with: documents)
            return index
        }
        relatednessBuild = build
        let index = await build.value
        relatedness = index
        relatednessBuild = nil
        return index
    }

    /// Keep the index current for one note. Cheap — one note's terms — and a
    /// no-op until something has actually built the index.
    private func updateRelatedness(url: URL, title: String, text: String) {
        guard let relatedness else { return }
        let document = RelatednessDocument(url: url, title: title,
                                           text: RetrievalText.prepare(text))
        Task { await relatedness.update(document) }
    }

    private func removeFromRelatedness(_ url: URL) {
        guard let relatedness else { return }
        Task { await relatedness.remove(url) }
    }

    /// Drop the index so the next use rebuilds it. Used when the whole
    /// collection is re-read and per-note patching cannot be trusted.
    private func invalidateRelatedness() {
        relatednessBuild?.cancel()
        relatednessBuild = nil
        relatedness = nil
    }

    // MARK: Link proposals

    /// "Never propose that link again", remembered per collection.
    ///
    /// `@ObservationIgnored` because `@Observable` rewrites stored properties
    /// into computed ones, and `lazy` cannot survive that — and because nothing
    /// observes this: it is consulted when proposals are generated, never
    /// rendered.
    @ObservationIgnored private lazy var declinedLinks = DeclinedLinkStore(collectionRoot: rootURL)

    /// Every note that could be linked to, with its aliases.
    private var linkCandidates: [LinkCandidate] {
        notes.map { LinkCandidate(title: $0.title, url: $0.fileURL,
                                  aliases: search.aliases(of: $0.fileURL)) }
    }

    /// Links this note's text names but does not make, best candidates only.
    ///
    /// **Two signals, intersected, because neither is a link on its own.** A
    /// title mention says "these words appear here" — and on the measured vault
    /// that alone yields ~15 proposals per note of which 0.8% match a link the
    /// author independently chose to make, which is a wall of noise rather than
    /// a feature. Relatedness says "these two notes are about the same things".
    /// A note you *named* and are *demonstrably writing about* is much closer to
    /// something worth linking.
    ///
    /// Measured (`docs/semantic-retrieval-benchmark.md`): keeping the ten
    /// most-related mentions retains 93% of the author's own links while cutting
    /// the proposal count by more than half. The cap matters more than the
    /// ordering — with ten shown in reading order, stopping early is cheap.
    ///
    /// Low proposal precision costs *review time*, never correctness: nothing is
    /// written without confirmation. That is the whole reason this feature is a
    /// review rather than a pass.
    func linkProposals(in text: String, for noteURL: URL?, limit: Int = 10) async -> [LinkProposal] {
        let candidates = linkCandidates
        let declined = declinedLinks.all
        let found = await Task.detached(priority: .userInitiated) {
            LinkProposals.proposals(in: text, candidates: candidates,
                                    declined: declined, excludingNoteAt: noteURL)
        }.value
        guard found.count > limit else { return found }

        // Rank by relatedness, keep the best, then restore reading order — the
        // review shows each proposal in its own context, so document order is
        // what makes a sequence of them feel like reading the note.
        let neighbours = await relatedNotes(to: text, excluding: noteURL, limit: 200)
        var rank: [URL: Int] = [:]
        for (position, neighbour) in neighbours.enumerated() { rank[neighbour.url] = position }
        return found
            .sorted { (rank[$0.targetURL] ?? .max) < (rank[$1.targetURL] ?? .max) }
            .prefix(limit)
            .sorted { $0.range.location < $1.range.location }
    }

    func declineLink(_ proposal: LinkProposal) {
        declinedLinks.decline(
            LinkProposals.declineKey(phrase: proposal.phrase, target: proposal.targetTitle))
    }

    /// Forget every "never" — the only way back for a decision made in haste.
    func resetDeclinedLinks() { declinedLinks.reset() }

    /// The opening of a note, for judging a proposed link without leaving the
    /// review. Front matter stripped: it is metadata, and it is what the top of
    /// the file actually holds.
    func openingLines(of url: URL, limit: Int = 400) async -> String {
        await offMain {
            guard let raw = try? FileIO.readString(at: url) else {
                return "Couldn't read that note."
            }
            let body = FrontMatter.body(of: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "This note is empty." : String(body.prefix(limit))
        }
    }

    // MARK: Per-collection subsystems (isolated to this collection)

    /// The collection's `[[wiki-link]]` / backlink index.
    let linkGraph = LinkGraph()

    /// Full-text search + fuzzy "Open Quickly" index over this collection.
    let search = CollectionSearchModel()

    /// Git status + operations for this collection's repository.
    let git = GitService()

    /// Bookmarked notes within this collection.
    let bookmarks = BookmarksStore()

    /// The last file-operation failure, for the shell to surface as an alert.
    /// A user-initiated create/rename/duplicate/delete/move that fails on disk
    /// (permissions, name collision, sandbox) sets this instead of silently
    /// no-op'ing. Cleared when the shell presents it. (Cross-platform — the note
    /// operations that set it exist on both macOS and iOS.)
    var lastError: String?

    /// Record a user-facing file-operation failure.
    /// Surface a file-operation failure — **never while the user is typing**.
    ///
    /// `FileOperationErrorAlert` presents on `lastError != nil`, and a modal
    /// takes first responder. So an error raised mid-sentence did not merely
    /// interrupt: it took the keyboard away, and because the alert appears over
    /// the editor with the caret gone, what it reported was often unreadable
    /// before it was dismissed. A save failing on a File Provider volume is
    /// exactly the error most likely to arrive while typing, which made this
    /// the worst possible pairing.
    ///
    /// Held until the burst ends. The failure is not lost — it is reported to
    /// someone who has stopped to read it.
    func report(_ message: String) { lastError = message }

    /// Renders `![[Note]]` transclusions to inline images (cross-platform: the
    /// live editor's block-embed renderer uses it on both macOS and iOS).
    let embedProvider = CollectionEmbedProvider()

    /// Standardised paths this collection wrote itself, with when — so a change
    /// notification can be recognised as the churn from our own autosaves (and
    /// their atomic temp files) instead of re-scanning the whole collection on
    /// every save.
    ///
    /// **Cross-platform, because the writes are.** This lived beside the macOS
    /// file watcher on the assumption that only FSEvents could ever hear about
    /// them. It cannot: `FileIO.write` coordinates through
    /// `NSFileCoordinator(filePresenter: nil)`, and *nil excludes no presenter*,
    /// so iOS's own `DirectoryPresenter` is told about every write the app makes.
    /// With the filter behind a `#if`, each 600 ms autosave woke the presenter,
    /// which debounced 400 ms and then re-walked the entire vault — the exact
    /// storm this was written to prevent, running unopposed on the platform that
    /// can least afford it.
    private var recentSelfWrites: [String: Date] = [:]

    /// How long a write of our own goes on explaining a change notification.
    ///
    /// **Sized for a File Provider volume, not a local disk.** At 3s this was
    /// too short and the symptom was severe: on an iCloud Drive vault FSEvents
    /// delivered our own autosave 3,684 ms after we wrote it, so the write had
    /// already left the window and every save scheduled a full 2,020-note walk
    /// — a scan every few seconds while typing. Sometimes the notification
    /// arrived after `selfWriteMemory` too, and the log was empty (`selfWrites=0`
    /// in the stall log).
    private static let selfWriteWindow: TimeInterval = 12

    /// How long the log of our own writes is kept at all — a little longer than
    /// the window, so a notification arriving late still finds its entry.
    private static let selfWriteMemory: TimeInterval = 15

    /// Coalesces bursts of external changes (a co-editing app like Obsidian
    /// autosaving, or iCloud streaming a file down in pieces) into a single
    /// scan + reconcile, instead of re-walking the whole vault per event.
    private var externalReconcileTask: Task<Void, Never>?

    /// How long a reconcile waits for the burst to end before scanning.
    private static let reconcileDebounce: Duration = .milliseconds(400)

    /// Debounced index refresh scheduled after an editor save (the note *set*
    /// is unchanged, so no re-scan is needed — only the content-derived index).
    private var deriveTask: Task<Void, Never>?

    /// Whatever this platform notices changes with — FSEvents or a file
    /// presenter. One property, because `Collection` only ever asks it to start
    /// and stop; the mechanisms differ inside `DirectoryObserver`.
    #if os(macOS)
    private var observer: FileWatcher?
    #else
    private var observer: DirectoryPresenter?
    #endif

    /// Coalesces `.git` churn into one status read (a checkout touches hundreds
    /// of files in there). Was macOS-only, so an external pull on iPad moved the
    /// branch and the change count and the status bar went on asserting the old
    /// ones indefinitely.
    private var gitRefreshTask: Task<Void, Never>?

    private var securityScoped = false

    /// The Uniform Type Identifier used to recognise Markdown files.
    nonisolated private static let markdownType: UTType =
        UTType("net.daringfireball.markdown")
        ?? UTType(filenameExtension: "md")
        ?? .plainText

    /// Whether `url` is a Markdown note. Takes the content type as a parameter
    /// because the caller has usually just read it as part of a resource-values
    /// fetch, and asking the filesystem again is a second `stat` per file.
    nonisolated static func isMarkdown(_ url: URL, contentType: UTType?) -> Bool {
        contentType?.conforms(to: markdownType) == true
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: markdownType) == true
    }

    /// **The** canonical form of a file URL in this app.
    ///
    /// Identity here is not cosmetic: `Note.id` *is* its file URL, the sidebar's
    /// selection is a URL, and a self-write is recognised by comparing paths. So
    /// two spellings of the same file mean a selected note that cannot be found
    /// (a click that does nothing) or an autosave mistaken for someone else's
    /// edit (a spurious rescan). The audit found four different normalisations
    /// across `Collection.id`, scanned URLs, `recentSelfWrites` and
    /// `AgentTool.isWithinRoot` — on a `/var`- or symlink-rooted vault those
    /// disagree, and the app treats its own writes as external changes.
    ///
    /// Applied to `rootURL` at init, so every URL the scan derives from it is
    /// already canonical and no per-note conversion is needed.
    nonisolated static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    init(rootURL: URL) {
        // **`rootURL` is stored exactly as granted, never canonicalised.**
        //
        // On iOS a security-scoped URL grants access to *that exact URL*, so
        // rewriting it — `resolvingSymlinksInPath()` turns `/var/…` into
        // `/private/var/…` — hands back a path the grant does not cover:
        // `startAccessingSecurityScopedResource()` then returns false and every
        // read of the collection fails. The note list still appears (it was
        // built while the picker's own scope was held) but opening a note shows
        // nothing, which is precisely what an iPad reported.
        //
        // Canonical form is for *identity* — `id`, and comparisons — not for the
        // URL the app actually reads through. `recentSelfWrites` already
        // normalises on both write and read, so it never needed this either.
        self.rootURL = rootURL
        self.id = Self.canonical(rootURL).path
        // Default on: a collection that silently withheld half its contents on
        // first open would be lying by omission before the user ever chose.
        let key = Self.showFilesKey(rootURL.standardizedFileURL.path)
        self.showsNonNoteFiles = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        git.rootURL = rootURL
        bookmarks.load(rootURL: rootURL)
    }

    // MARK: - Scanning

    /// Enumerate `rootURL` into notes / attachments / folders, or **`nil` if the
    /// walk was cancelled**.
    ///
    /// The optional is the whole point. This used to return `([], [], [])` on
    /// cancellation — indistinguishable from a genuinely empty folder — and
    /// `scan()` handed that straight to `apply`, emptying the collection and
    /// then clearing `.stale`, so the app asserted a complete and correct
    /// picture of nothing. A comment two dozen lines down said "the caller
    /// discards a cancelled walk's partial results"; one caller did and the
    /// other did not. A type the compiler checks beats a comment the next
    /// caller does not read.
    ///
    /// `nonisolated` and pure so it can run on a background executor — a full
    /// directory walk of a large collection is thousands of `stat` calls that
    /// shouldn't block the UI.
    nonisolated static func enumerate(_ rootURL: URL) -> (notes: [Note], attachments: [CollectionFile], folders: [URL])? {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], [], [])
        }

        var discovered: [Note] = []
        var discoveredFiles: [CollectionFile] = []
        var discoveredFolders: [URL] = []

        for case let fileURL as URL in enumerator {
            // A superseded walk should stop rather than run to completion behind
            // the one that replaced it: a bulk `git checkout` fires several
            // watcher batches, and each used to put another full walk on the
            // disk. The caller discards a cancelled walk's partial results.
            if Task.isCancelled { return nil }
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else {
                continue
            }
            if resourceValues.isDirectory == true {
                discoveredFolders.append(fileURL)
                continue
            }
            guard resourceValues.isRegularFile == true else { continue }
            let modified = resourceValues.contentModificationDate ?? .distantPast

            let isMarkdown = resourceValues.contentType?.conforms(to: Self.markdownType) == true
                || UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: Self.markdownType) == true

            if isMarkdown {
                let onlineOnly = resourceValues.isUbiquitousItem == true
                    && resourceValues.ubiquitousItemDownloadingStatus == .notDownloaded
                discovered.append(Note(
                    title: fileURL.deletingPathExtension().lastPathComponent,
                    fileURL: fileURL,
                    lastModified: modified,
                    fileSize: resourceValues.fileSize ?? 0,
                    isOnlineOnly: onlineOnly
                ))
            } else {
                discoveredFiles.append(CollectionFile(url: fileURL, lastModified: modified))
            }
        }

        return (
            discovered.sorted { $0.lastModified > $1.lastModified },
            discoveredFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            discoveredFolders
        )
    }

    /// Scan synchronously (used by the infrequent, user-initiated file
    /// mutations that need the updated note immediately afterwards).
    ///
    /// A cancelled walk is **discarded**, never applied.
    /// Synchronous whole-folder scan. **Tests only.**
    ///
    /// It walks the entire tree on the main actor, so on anything larger than a
    /// fixture it blocks the editor for the length of the walk — and on a cloud
    /// folder each listing is a blocking XPC call to the File Provider. Every
    /// production path uses `scanOffMain()`. Kept because it makes the test
    /// suite readable, and dangerous enough to say so here.
    func scan() {
        if let reason = Self.unavailability(of: rootURL) { markUnavailable(reason); return }
        guard let result = Self.enumerate(rootURL) else { return }
        apply(result)
    }

    /// Adopt a scan's results. The **only** place the note set is replaced, so
    /// that "we looked and the folder was unreadable" can never be mistaken for
    /// "we looked and the folder was empty".
    private func apply(_ result: (notes: [Note], attachments: [CollectionFile], folders: [URL])) {
        MainActorWatchdog.note("apply(\(result.notes.count) notes) — observers now invalidated")
        notes = result.notes
        attachments = result.attachments
        folders = result.folders
        revision &+= 1
        // A completed scan is by definition a complete picture, so it clears a
        // stale index — but it must not overwrite an unavailability that the
        // watcher reported while the walk was in flight.
        if case .stale = state { state = .ready }
    }

    /// Scan off the main actor, then apply the results — used for startup and
    /// external-change reconciliation, where a main-thread directory walk of a
    /// large collection would otherwise freeze the UI.
    /// Scan off the main actor, publishing as the walk proceeds.
    ///
    /// A `ResumableTreeWalk` rather than a `FileManager.enumerator`, because the
    /// enumerator returns only when finished, cannot be checkpointed, and yields
    /// nothing when cancelled. Everything below follows from that: results
    /// appear as they are found, an interrupted scan resumes from where it
    /// stopped, and one unreadable folder costs its subtree rather than the scan.
    func scanOffMain() async {
        // **One walk at a time.** Concurrent scans of the same collection share
        // a single checkpoint file, so two overlapping passes race over which
        // one's frontier is authoritative — and the loser's partial frontier can
        // be the one that survives, which is how a resumed pass ends up
        // publishing the tail of a vault. A second caller therefore joins the
        // walk already running instead of starting a rival, and asks for one
        // more pass afterwards so nothing that changed mid-walk is missed.
        if let inFlight = scanInFlight {
            rescanWhenIdle = true
            await inFlight.value
            return
        }
        let scan = Task { @MainActor [weak self] in await self?.performScan() ?? () }
        scanInFlight = scan
        // **Forward the caller's cancellation.** An unstructured `Task` inherits
        // priority and task-locals but *not* cancellation, so without this the
        // guard silently un-cancels every scan — and a scan that cannot be
        // cancelled goes on to publish a picture nobody is waiting for, which is
        // how a cancelled rescan emptied a collection.
        await withTaskCancellationHandler {
            await scan.value
        } onCancel: {
            scan.cancel()
        }
        scanInFlight = nil
        if rescanWhenIdle {
            rescanWhenIdle = false
            await scanOffMain()
        }
    }

    /// Whether a walk is running, and whether another was asked for while it was.
    private var scanInFlight: Task<Void, Never>?
    private var rescanWhenIdle = false

    private func performScan() async {
        let collectionID = id
        let source = LocalTreeSource(root: rootURL, includesNonNoteFiles: showsNonNoteFiles)
        let resume = Self.resumePoint(for: collectionID)
        /// Whether this pass will visit the whole tree, and may therefore
        /// *define* the collection rather than merely add to it.
        ///
        /// Not `resume == nil`: after a completed walk `resumePoint` returns a
        /// synthetic checkpoint whose frontier is the root, purely to carry the
        /// previous directory total for the progress bar. A first attempt at
        /// this guard read that as "resumed" and sent almost every scan down
        /// the merge path — which never removes anything, so hiding non-note
        /// files stopped hiding them. The question is not whether there was a
        /// checkpoint; it is whether the walk starts at the root.
        let startedFromRoot = resume.map { $0.frontier.isEmpty || $0.frontier == [""] } ?? true

        // The collection already has a picture of the folder. An interrupted
        // rescan would only ever hold a *subset* of it, so replacing the old one
        // as we go would lose notes from view — the same mistake as emptying a
        // collection whose folder we couldn't read. Fill in live only when there
        // is nothing to lose.
        let isFirstPicture = notes.isEmpty && attachments.isEmpty

        let reveal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.showsScanProgress = true
        }
        defer {
            reveal.cancel()
            showsScanProgress = false
            scanProgress = nil
            currentScan = nil
        }

        // **Everything below the walk runs off the main actor.**
        //
        // It used to be the other way round: only the *producer* was detached,
        // and the main actor ran the consumer loop — accumulating each batch,
        // writing two `@Observable` progress properties per directory, and every
        // 150ms sorting the whole accumulated note list and rebuilding the
        // sidebar outline. On a 2,000-note vault that measured **2.3 seconds**
        // of blocked main actor (`MainActorBudgetTests`), which is the editor
        // freezing for the length of the scan.
        //
        // Now one detached task walks, accumulates and sorts, and hands back
        // finished, already-sorted pictures. The main actor's entire job is to
        // assign one value, at most a few times a second.
        let remoteState: (cacheRoot: URL, dehydrated: Set<String>, trueSizes: [String: Int])? =
            remote.map { ($0.cacheRoot, $0.dehydratedRelativePaths, $0.manifest.sizes) }

        // Bounded, so a fast filesystem cannot pile work onto a slow consumer.
        // The old stream was unbounded with no backpressure, which is why a
        // cloud vault's burst listings saturated the main actor.
        let (updates, continuation) = AsyncStream<ScanUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(2))

        let walk = Task.detached(priority: .userInitiated) { () -> WalkResult in
            defer { continuation.finish() }
            var found = ScanAccumulator()
            if let remoteState {
                found.cacheRoot = remoteState.cacheRoot
                found.dehydrated = remoteState.dehydrated
                found.trueSizes = remoteState.trueSizes
            }
            var lastEmit = ContinuousClock.now

            let result = await ResumableTreeWalk.run(
                source: source,
                resuming: resume,
                onCheckpoint: { WalkCheckpointStore.save($0, for: collectionID) },
                onBatch: { batch in
                    found.add(batch)
                    // Coalesce. Between emissions nothing crosses to the main
                    // actor at all — not even progress, which used to invalidate
                    // every observing view once per directory.
                    guard ContinuousClock.now - lastEmit > .milliseconds(250) else { return }
                    lastEmit = ContinuousClock.now
                    continuation.yield(.inProgress(
                        picture: isFirstPicture ? found.sorted : nil,
                        progress: batch.progress))
                })

            // The final picture is sorted here too, off the main actor. It
            // carries the progress as well: a collection small enough to finish
            // inside one coalescing window emits no `.inProgress` update at all,
            // and the first version of this dropped `hiddenFileCount` on the
            // floor for every such collection — caught by
            // `hiddenNonNoteFilesAreCountedNotSilentlyDropped`, which is the
            // second time that test has caught a coalescing mistake.
            continuation.yield(.finished(picture: found.sorted, result: result))
            return result
        }
        currentScan = walk

        var finalPicture: ScanPicture?
        let result = await withTaskCancellationHandler {
            for await update in updates {
                switch update {
                case .inProgress(let picture, let progress):
                    scanProgress = progress
                    hiddenFileCount = progress.filesOmitted
                    if let picture { apply(picture) }   // already sorted
                case .finished(let picture, let walkResult):
                    finalPicture = picture
                    hiddenFileCount = walkResult.progress.filesOmitted
                }
            }
            return await walk.value
        } onCancel: {
            // `Task.detached` does not inherit cancellation, so without this the
            // walk would run on after we stopped listening — burning a full
            // cloud-tree traversal nobody is waiting for.
            walk.cancel()
        }

        if let reason = result.unavailable { markUnavailable(reason); return }
        guard let found = finalPicture else {
            // The stream ended without a final picture: the walk was cancelled
            // before it finished. Publish nothing — the previous picture is
            // better than a subset, which is the mistake that lost a note.
            markStale(.scanIncomplete)
            return
        }

        // **Our own cancellation outranks the walk's verdict.** Iterating an
        // AsyncStream ends when the *consuming* task is cancelled, so the loop
        // above can stop early while the detached walk goes on to finish and
        // report `isComplete`. Publishing the accumulator then would replace the
        // note list with however little arrived before we stopped listening —
        // which is how a cancelled rescan emptied a collection outright.
        let sawWholeTree = result.isComplete && !Task.isCancelled

        if sawWholeTree {
            // **"Complete" means the walk finished, not that it saw everything.**
            // A resumed walk starts at a stored frontier and accumulates only
            // the directories still ahead of it, then reports `isComplete` —
            // which is true of the *walk* and false of the *tree*. Publishing
            // that as authoritative replaced the note list with the tail of the
            // vault, and notes the user was looking at simply vanished.
            //
            // So a resumed pass merges into what is already known, and only a
            // pass that began at the root is allowed to define the whole
            // picture (which is also what lets it remove deleted notes).
            if startedFromRoot {
                apply(found)
            } else {
                applyMerging(found)
            }
            state = isAvailable ? .ready : state
            WalkCheckpointStore.rememberTotal(result.progress.directoriesVisited, for: collectionID)
        } else {
            // A partial pass. Show it only if there was nothing better, and say
            // the list is a subset either way so search can disclose it.
            if isFirstPicture { apply(found) }
            markStale(.scanIncomplete)
        }
    }

    /// One coalesced update from a scan running off the main actor.
    ///
    /// The picture is already sorted when it arrives — sorting is the expensive
    /// part and it belongs to the walk's task, not to the actor that draws.
    private enum ScanUpdate: Sendable {
        case inProgress(picture: ScanPicture?, progress: WalkProgress)
        case finished(picture: ScanPicture, result: WalkResult)
    }

    /// Where to resume from, or a fresh start that still remembers how big the
    /// tree was last time (which is what makes the second scan's bar real).
    private static func resumePoint(for collectionID: String) -> WalkCheckpoint? {
        guard let stored = WalkCheckpointStore.load(for: collectionID) else { return nil }
        guard stored.frontier.isEmpty else { return stored }
        return WalkCheckpoint(frontier: [""], directoriesVisited: 0, itemsSeen: 0,
                              previousTotalDirectories: stored.previousTotalDirectories)
    }

    /// A finished, already-sorted picture of the folder.
    ///
    /// Named rather than an anonymous tuple because it now crosses an isolation
    /// boundary: the walk's task produces it and the main actor consumes it, so
    /// it has to be `Sendable` and it has to be obvious at every call site that
    /// the sorting has already happened somewhere else.
    typealias ScanPicture = (notes: [Note], attachments: [CollectionFile], folders: [URL])

    /// Accumulates a walk's batches into the collection's three lists.
    /// `nonisolated` because it is nested inside a `@MainActor` class, which
    /// would otherwise make it main-actor too — and the walk's task calls
    /// `add` per directory and `sorted` at the end, so a main-actor accumulator
    /// drags the whole walk back onto the main thread. See the header of
    /// `ResumableTreeWalk.swift`.
    nonisolated private struct ScanAccumulator: Sendable {
        private var notes: [Note] = []
        private var files: [CollectionFile] = []
        private var folders: [URL] = []

        /// Cache-relative paths whose content has not been downloaded, from a
        /// remote mirror's manifest. Empty for an ordinary local collection.
        ///
        /// This is the hydration gate. `FileIO.isMaterialized` answers only for
        /// *iCloud* items and returns true for anything else — including a
        /// mirror placeholder — so without this the indexers would read a
        /// zero-byte stand-in as an empty note, cache that, and the editor would
        /// then load "" and upload it over the real note on the provider.
        var dehydrated: Set<String> = []
        var trueSizes: [String: Int] = [:]
        var cacheRoot: URL?

        mutating func add(_ batch: WalkBatch) {
            for child in batch.children {
                if child.isDirectory { folders.append(child.url); continue }
                var onlineOnly = child.isOnlineOnly
                var size = child.size
                if let cacheRoot {
                    let relative = RemoteMirror.relativePath(of: child.url, in: cacheRoot)
                    onlineOnly = dehydrated.contains(relative)
                    // A placeholder is 0 bytes on disk; report what the file
                    // actually weighs on the provider.
                    if let real = trueSizes[relative], onlineOnly { size = real }
                }
                if child.isMarkdown {
                    notes.append(Note(title: child.url.deletingPathExtension().lastPathComponent,
                                      fileURL: child.url,
                                      lastModified: child.modified,
                                      fileSize: size,
                                      isOnlineOnly: onlineOnly))
                } else {
                    files.append(CollectionFile(url: child.url, lastModified: child.modified))
                }
            }
        }

        var sorted: ScanPicture {
            (notes.sorted { $0.lastModified > $1.lastModified },
             files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
             folders)
        }
    }



    /// Fold a **partial** pass into the current picture instead of replacing it.
    ///
    /// Freshly-walked entries win, and anything the pass did not reach is kept.
    /// The trade is deliberate and one-directional: a note deleted outside the
    /// app while a resumed pass was running lingers in the list until the next
    /// pass that starts from the root. Showing a note that has gone is a
    /// correction; hiding a note that exists is a scare, and this app has now
    /// done the second to its own author.
    private func applyMerging(_ fresh: ScanPicture) {
        let walkedNotes = Set(fresh.notes.map(\.fileURL))
        let walkedFiles = Set(fresh.attachments.map(\.url))

        let mergedNotes = (notes.filter { !walkedNotes.contains($0.fileURL) } + fresh.notes)
            .sorted { $0.lastModified > $1.lastModified }
        let mergedFiles = (attachments.filter { !walkedFiles.contains($0.url) } + fresh.attachments)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let mergedFolders = Array(Set(folders).union(fresh.folders))

        apply((notes: mergedNotes, attachments: mergedFiles, folders: mergedFolders))
    }

    // MARK: - Remote collections (cross-platform)

    /// Ask the provider what has changed and apply it. Cheap when the provider
    /// has a delta cursor; a full metadata sync when it does not.
    func refreshFromProvider() async {
        guard let remote else { return }
        do {
            _ = try await remote.refresh()
            await scanOffMain()
            refreshDerived()
        } catch {
            report("Couldn't refresh from \(remote.store.providerName): \(error.localizedDescription)")
        }
    }

    /// Fetch a remote note's real content if the cache only holds a placeholder.
    /// Safe and cheap to call unconditionally — it returns immediately for a
    /// local collection or an already-hydrated file.
    func hydrateIfNeeded(_ url: URL) async {
        guard let remote, !remote.isHydrated(localURL: url) else { return }
        do {
            try await remote.hydrate(localURL: url)
            // Keep the cache bounded, never evicting what was just opened or
            // what is open in a tab.
            remote.evictIfNeeded(keeping: pinnedCachePaths(including: url))
            // **One note changed, so update one note.** This used to
            // `await scanOffMain()` here, and `hydrateIfNeeded` is wired as
            // `tabs.prepareToOpen` — so *selecting* a note in a cloud collection
            // waited on a walk of the whole folder before the editor could open
            // it, and a walk that republished the list could deselect the note
            // it was opening. Downloading the bytes is work the editor genuinely
            // needs; re-reading the folder is not.
            adopt(hydrated: url)
            reindexSoon()
        } catch {
            report("Couldn't download “\(url.lastPathComponent)” from \(remote.store.providerName): \(error.localizedDescription)")
        }
    }

    /// Mark a just-downloaded note as local, without re-walking the folder.
    private func adopt(hydrated url: URL) {
        guard let index = notes.firstIndex(where: { $0.fileURL == url }) else { return }
        let note = notes[index]
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        notes[index] = Note(title: note.title, fileURL: note.fileURL,
                            lastModified: values?.contentModificationDate ?? note.lastModified,
                            fileSize: values?.fileSize ?? note.fileSize,
                            isOnlineOnly: false)
        revision &+= 1
    }

    /// Cache-relative paths that must survive eviction: whatever was just
    /// opened, plus anything the editor is currently holding.
    private func pinnedCachePaths(including url: URL) -> Set<String> {
        guard let remote else { return [] }
        return [RemoteMirror.relativePath(of: url, in: remote.cacheRoot)]
    }

    /// Download every note whose content isn't local yet, so a content search
    /// can actually see them.
    ///
    /// Search skips them by default, and that default is right — a query must
    /// never quietly pull a whole account down. But "right by default" is not
    /// the same as "the only option", and without this the omission is a wall
    /// rather than a choice. Reports how many were fetched.
    @discardableResult
    func downloadAllForSearch(progress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> Int {
        let pending: [URL]
        if let remote {
            pending = notes.filter(\.isOnlineOnly).map(\.fileURL)
                + attachments.map(\.url).filter { !remote.isHydrated(localURL: $0) }
        } else {
            pending = notes.filter(\.isOnlineOnly).map(\.fileURL)
        }
        guard !pending.isEmpty else { return 0 }

        var fetched = 0
        for url in pending {
            if Task.isCancelled { break }
            do {
                if let remote {
                    try await remote.hydrate(localURL: url)
                } else {
                    // A File-Provider item: ask the OS to materialise it, which
                    // is the same thing opening the note would do.
                    let target = url
                    try await Task.detached(priority: .utility) { try FileIO.download(at: target) }.value
                }
                fetched += 1
                progress(fetched, pending.count)
            } catch {
                report("Couldn't download “\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        await scanOffMain()
        refreshDerived()
        return fetched
    }

    /// Download one item, whichever kind of "not here" it is.
    ///
    /// The two menu call sites used to go straight to
    /// `try? FileIO.download(at:)` — `startDownloadingUbiquitousItem`, which is
    /// only meaningful for a File-Provider item. A direct-API mirror note is a
    /// zero-byte placeholder in the app's own container, not a ubiquitous item,
    /// so that call threw, the `try?` ate it, and "Download" was an enabled menu
    /// row that did nothing on every Dropbox/Box/Drive/OneDrive collection.
    /// This is the same dispatch `downloadAllForSearch` already makes.
    func download(_ url: URL) async {
        do {
            if let remote {
                try await remote.hydrate(localURL: url)
                adopt(hydrated: url)
                reindexSoon()
            } else {
                try await Task.detached(priority: .utility) { try FileIO.download(at: url) }.value
            }
        } catch {
            report("Couldn't download “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    /// How many of this collection's items a content search cannot see.
    ///
    /// Counts **both** kinds of "not here": a File-Provider note the OS is
    /// holding online-only, and a direct-API placeholder. Counting only the
    /// latter left the *recommended* path — a mounted cloud folder — with no
    /// notice and no offer, which is exactly backwards.
    var notLocalCount: Int {
        let onlineOnlyNotes = notes.filter(\.isOnlineOnly).count
        guard let remote else { return onlineOnlyNotes }
        return onlineOnlyNotes
            + attachments.filter { !remote.isHydrated(localURL: $0.url) }.count
    }

    /// Whether this note's bytes are actually present.
    func hasContent(_ url: URL) -> Bool {
        guard let remote else { return true }
        return remote.isHydrated(localURL: url)
    }

    // MARK: - Lifecycle

    /// Begin the security scope, do an initial scan, refresh derived data and Git
    /// status, and start watching the folder for external changes.
    ///
    /// **One body for both platforms.** iOS used to keep a shorter copy of this,
    /// and everything the copy quietly left out was a bug: no cache-first
    /// `refreshDerived`, so every launch re-read the whole vault instead of
    /// hitting a fingerprinted cache; no `linkGraph.load`, so backlinks, the
    /// graph view's edges and rename's link rewriting all consulted an empty
    /// graph; and no Git status, so an iPad never believed a real clone was a
    /// repository and hid the remote controls for the life of the collection.
    /// Only *how* the folder is watched is genuinely platform-specific, so that
    /// is the only part left behind a `#if`.
    /// Every folder implied by a set of notes — the cache records files, and
    /// the sidebar needs the tree they sit in. Derived rather than walked, for
    /// the same reason the notes are.
    private static func folders(from notes: [Note], root: URL) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        let rootPath = root.standardizedFileURL.path
        for note in notes {
            var dir = note.fileURL.deletingLastPathComponent().standardizedFileURL
            while dir.path.hasPrefix(rootPath), dir.path != rootPath {
                guard seen.insert(dir.path).inserted else { break }
                out.append(dir)
                dir = dir.deletingLastPathComponent()
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    func activate(onExternalChange: @escaping @MainActor () -> Void) async {
        securityScoped = rootURL.startAccessingSecurityScopedResource()

        // **Open from the cache. Walk only when there is nothing to open
        // from.**
        //
        // This used to walk the whole vault on every launch before showing
        // anything — on a 2,000-note collection in iCloud that walk *is* the
        // startup, and it re-derived a picture the index cache already held.
        // A scan should answer a known change, and "the app launched" is not
        // one.
        //
        // What keeps this honest is that the watcher is started below: any
        // change made while the app was closed, or made by anything else while
        // it is open, arrives as a notification and reconciles then. The cache
        // is a starting point, not a claim that nothing moved.
        if let cached = CollectionIndexCache.notes(for: rootURL) {
            notes = cached
            folders = Self.folders(from: cached, root: rootURL)
            revision &+= 1
            MainActorWatchdog.note("activate — opened from cache (\(cached.count) notes), no walk")
        } else {
            await scanOffMain()
        }
        refreshDerived()
        // **Not awaited.** Git operations run on a FIFO queue, so `refreshStatus`
        // queues behind whatever is already in flight — and a push to a slow
        // remote can take a minute. Awaiting it here made *opening a collection*
        // wait on an unrelated network operation. The status is a badge; it can
        // arrive when it arrives.
        Task { await git.refreshStatus() }
        startObserving(onExternalChange: onExternalChange)
    }

    /// Stop watching and relinquish the security scope. Call before closing.
    func deactivate() {
        stopObserving()
        if securityScoped { rootURL.stopAccessingSecurityScopedResource(); securityScoped = false }
    }

    /// Bring the derived index (link graph, search, tags) up to date.
    ///
    /// Cache-first: each note's parsed metadata persists in the
    /// ``CollectionIndexCache`` fingerprinted by mtime + size, so only notes
    /// that actually changed since the cache was written are re-read and
    /// re-parsed — on a warm launch that is usually *none*, and the whole
    /// index is live in milliseconds instead of re-reading the collection.
    /// The graph and aggregates are then rebuilt from metadata entirely in
    /// memory, which keeps this correct for every kind of change.
    ///
    /// `force` ignores the cache and re-parses everything (the Rescan command).
    func refreshDerived(force: Bool = false) {
        embedProvider.update(notes: notes)
        let noteList = notes
        let root = rootURL
        deriveTask?.cancel()
        deriveTask = Task {
            let pairs = await Task.detached(priority: .userInitiated) { () -> [(note: Note, record: NoteIndexRecord)] in
                let cached = force ? [:] : (CollectionIndexCache.load(for: root) ?? [:])
                var pairs: [(note: Note, record: NoteIndexRecord)] = []
                var reparsed = 0
                for note in noteList {
                    let rel = CollectionIndexCache.relativePath(of: note.fileURL, in: root)
                    if let record = cached[rel], record.matches(note) {
                        pairs.append((note, record))
                    } else if FileIO.hasContentAvailable(note),
                              let text = try? FileIO.readString(at: note.fileURL) {
                        pairs.append((note, CollectionIndexCache.record(for: note, relativeTo: root, text: text)))
                        reparsed += 1
                    }
                    // An online-only note that isn't cached is skipped rather
                    // than downloaded: it still appears in the list (title from
                    // its filename), and is indexed when it's opened (which
                    // materializes it) or edited. This keeps first-open of a
                    // cloud vault from pulling every note local.
                }
                // Persist when anything was re-parsed or notes were removed.
                if reparsed > 0 || pairs.count != cached.count {
                    CollectionIndexCache.save(pairs.map { $0.record }, for: root)
                }
                return pairs
            }.value
            guard !Task.isCancelled else { return }

            MainActorWatchdog.measure("linkGraph.load(\(pairs.count) records)") {
                linkGraph.load(pairs: pairs)
            }
            await search.load(pairs: pairs)
            MainActorWatchdog.measure("derivedRevision bump → observers") {
                derivedRevision &+= 1
            }
        }
    }

    /// Rebuild everything from scratch, ignoring the index cache — the safety
    /// valve for when the index ever looks wrong.
    func rescan() {
        CollectionIndexCache.remove(for: rootURL)
        // **Drop the walk checkpoint too.** Without this, "rebuild everything
        // from scratch" quietly resumed from a stored frontier and walked only
        // part of the tree — so the one command offered as the escape hatch for
        // a wrong index reproduced the wrong index, and there was no way out of
        // the state from inside the app at all.
        WalkCheckpointStore.remove(for: id)
        invalidateRelatedness()
        Task {
            await scanOffMain()
            refreshDerived(force: true)
        }
    }

    // MARK: Watching the folder

    /// Start noticing changes. The mechanism is the platform's; the events and
    /// what they mean are not.
    private func startObserving(onExternalChange: @escaping @MainActor () -> Void) {
        stopObserving()
        #if os(macOS)
        let watcher = FileWatcher { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, onExternalChange: onExternalChange)
            }
        }
        watcher.start(url: rootURL)
        observer = watcher
        #else
        let presenter = DirectoryPresenter(root: rootURL) { [weak self] event in
            Task { @MainActor [weak self] in
                // The presenter speaks the same vocabulary the watcher does —
                // including `.rootChanged`, which it could not say at all while
                // its callback was "a subitem, or nothing".
                self?.handle(event, onExternalChange: onExternalChange)
            }
        }
        presenter.start()
        observer = presenter
        #endif
    }

    private func stopObserving() {
        observer?.stop()
        observer = nil
    }

    /// Turn what the observer said into what the collection should do about it.
    ///
    /// One handler for both platforms. It used to be two — `handle(_:)` over
    /// FSEvents flags and `presenterDidReportChange(at:)` over a URL — and they
    /// had drifted: only the macOS one refreshed Git status when `.git` churned.
    private func handle(_ event: DirectoryEvent,
                        onExternalChange: @escaping @MainActor () -> Void) {
        switch event {
        case .rootChanged:
            // Moved, renamed, or deleted. Re-check rather than assume: a rename
            // *back*, or an editor's atomic save-over of the folder, can raise
            // this while leaving a perfectly readable directory behind.
            if let reason = Self.unavailability(of: rootURL) {
                markUnavailable(reason)
                onExternalChange()
            } else {
                reconcileSoon(onExternalChange: onExternalChange)
            }

        case .unmounted:
            markUnavailable(.unmounted)
            onExternalChange()

        case .eventsDropped:
            // The observer is telling us its own change list is incomplete.
            // Nothing short of a full rescan can be trusted after this, and
            // until that lands the index is admittedly behind — which search
            // must disclose.
            markStale(.eventsDropped)
            reconcileSoon(onExternalChange: onExternalChange)

        case .itemsChanged(let paths):
            // `.git` churn is not a *content* change — `hasExternalChanges`
            // rightly filters it out, or every auto-commit would re-scan the
            // vault. But it is still news: an external `git pull`, checkout or
            // rebase moves the branch and the change count.
            if paths.contains(where: Self.isGitMetadata) { refreshGitSoon() }
            guard hasExternalChanges(in: paths) else { return }
            reconcileSoon(onExternalChange: onExternalChange)

        case .unspecifiedChange:
            // No path list, so nothing can be filtered — wait out whatever is
            // left of our own write window rather than re-scanning on our own
            // autosave.
            // **A notification we caused is not news, and delaying it does not
            // make it news.** This used to compute how much of the self-write
            // window was left and reconcile *after* it — so on iOS, whose
            // presenter never reports paths, every autosave still ended in a
            // full vault walk, merely postponed. That is why typing was
            // unusable there while macOS only wasted work.
            //
            // The cost of skipping is bounded: a genuine external change that
            // lands inside our own write window is picked up by the next
            // notification, by `recheckAvailability`, or on foreground.
            guard selfWriteSettleDelay == nil else {
                MainActorWatchdog.note("unspecifiedChange — ours, skipping the scan")
                return
            }
            MainActorWatchdog.note("unspecifiedChange — no recent self-write, scanning now")
            reconcileSoon(onExternalChange: onExternalChange)
        }
    }

    private nonisolated static func isGitMetadata(_ path: String) -> Bool {
        path.contains("/.git/") || path.hasSuffix("/.git")
    }

    /// Debounced Git status refresh. A checkout rewrites hundreds of files under
    /// `.git`, and re-reading status for each would queue hundreds of libgit2
    /// reads behind one another.
    private func refreshGitSoon() {
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.git.refreshStatus()
        }
    }

    /// How much of the self-write window is left to wait out, or `nil` when
    /// nothing we wrote can account for this notification.
    private var selfWriteSettleDelay: Duration? {
        guard let newest = recentSelfWrites.values.max() else { return nil }
        let remaining = Duration.seconds(Self.selfWriteWindow - Date().timeIntervalSince(newest))
        // Below the ordinary debounce there is nothing left to wait for — and a
        // *shorter* wait would defeat the coalescing it stands in for.
        guard remaining > Self.reconcileDebounce else { return nil }
        return remaining
    }

    /// Debounced rescan + reindex.
    ///
    /// A live co-editor (Obsidian) plus iCloud can rewrite files in rapid
    /// bursts. Without coalescing, each event drove a full off-main vault scan +
    /// index rebuild + editor reconcile — which, while the open note is being
    /// co-edited, stutters the UI and keeps resetting the editor's scroll
    /// position.
    ///
    /// Cross-platform because the reasoning is: both watchers want exactly this.
    /// The iOS copy that used to live in the other branch had also quietly lost
    /// the Git refresh below, so an iPad's change count went stale the moment
    /// anything happened outside the app.
    private func reconcileSoon(onExternalChange: @escaping @MainActor () -> Void) {
        reconcileSoon(onExternalChange: onExternalChange, after: Self.reconcileDebounce)
    }

    /// The same, held off for `delay` — long enough that a change we may have
    /// caused ourselves has stopped being news.
    private func reconcileSoon(onExternalChange: @escaping @MainActor () -> Void,
                               after delay: Duration) {
        externalReconcileTask?.cancel()
        externalReconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // No gate here any more, because there is nothing to gate
            // against: the app no longer writes to the vault while the user is
            // typing, so the self-write that used to trigger this walk — and
            // then run it mid-sentence — cannot happen. The trigger is gone
            // rather than deferred.
            MainActorWatchdog.note("external reconcile — full vault walk begins")
            await self.scanOffMain()
            self.refreshDerived()
            // Files changed under a repository, so its change count did too.
            // Without this the status bar kept asserting whatever it read at
            // activate — including a branch name an external checkout had since
            // moved on from.
            if self.git.status.isRepository { await self.git.refreshStatus() }
            onExternalChange()
        }
    }

    /// Remember that we just wrote `url`, so a change notification about it is
    /// recognised as ours rather than mistaken for someone else's edit.
    ///
    /// Prunes as it records. The log is only ever read for the last few seconds,
    /// and the read that used to prune it (`hasExternalChanges`) needs a path
    /// list — which a file presenter never supplies, so on iOS nothing else
    /// would ever clear it.
    private func rememberSelfWrite(_ url: URL, at time: Date = Date()) {
        recentSelfWrites = recentSelfWrites.filter {
            time.timeIntervalSince($0.value) < Self.selfWriteMemory
        }
        recentSelfWrites[Self.normalize(url.path)] = time
    }

    /// Whether `paths` contains a change we didn't cause. Filters out our own
    /// recent autosaves and hidden-file churn (atomic-write temp files, the
    /// `.git` directory that auto-commit touches, `.DS_Store`), so the app's own
    /// writes never trigger a full re-scan + re-index of the collection.
    ///
    /// Cross-platform along with the log it reads, though only a watcher that
    /// reports *which* paths changed can ask it: the iOS presenter path asks the
    /// weaker, path-less form of the same question in `selfWriteSettleDelay`.
    /// Kept here, and not back inside the macOS branch, so that the day the
    /// presenter starts forwarding its subitem URL there is one filter to point
    /// it at rather than a second one to write.
    private func hasExternalChanges(in paths: [String]) -> Bool {
        let now = Date()
        recentSelfWrites = recentSelfWrites.filter {
            now.timeIntervalSince($0.value) < Self.selfWriteMemory
        }
        // Directories whose contents we just wrote. An atomic save is a write
        // to a temp file plus a rename, and the rename mutates the *containing
        // directory* — so FSEvents reports the note's folder and, for a note at
        // the top level, the vault root, alongside the note itself. Neither is
        // independent news: whatever happened inside them is described by the
        // file events in the same batch, which this filter already judges. Left
        // unfiltered they are never in `recentSelfWrites` (which holds files)
        // and never start with a dot, so **every autosave scheduled a full
        // vault walk** — measured on a 2,020-note vault as a scan every few
        // seconds while typing.
        //
        // Suppressing by *parenthood* rather than by "is a directory" keeps the
        // events that matter: an externally renamed or deleted folder still
        // reports a directory we did not write into, and still rescans.
        // Every ancestor, not just the immediate parent. A rename mutates the
        // containing directory, and FSEvents reports the vault root as well —
        // which is the *grandparent* of a note in a folder. Suppressing only the
        // parent silenced `Events` and left `My Vault` still scheduling a walk.
        var selfWriteParents = Set<String>()
        let rootKey = Self.normalize(rootURL.path)
        for (key, at) in recentSelfWrites where now.timeIntervalSince(at) < Self.selfWriteWindow {
            var dir = (key as NSString).deletingLastPathComponent
            while dir.count >= rootKey.count, dir != "/" {
                selfWriteParents.insert(dir)
                if dir == rootKey { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }

        let external = paths.filter { path in
            if (path as NSString).lastPathComponent.hasPrefix(".") { return false }
            let key = Self.normalize(path)
            if let wroteAt = recentSelfWrites[key],
               now.timeIntervalSince(wroteAt) < Self.selfWriteWindow { return false }
            if selfWriteParents.contains(key) { return false }
            // The atomic write's own temp sibling. `data.write(options: .atomic)`
            // inside a sandbox writes `Note.md.sb-d4839701-Q57X0e` beside the
            // note and renames it over the top. It has **no leading dot**, so the
            // hidden-file filter never sees it, and it is not the path we
            // recorded — so it read as someone else's edit and walked the whole
            // vault. Measured on an iPad: one such event per save.
            if recentSelfWrites.contains(where: { wrote, at in
                now.timeIntervalSince(at) < Self.selfWriteWindow && key.hasPrefix(wrote + ".")
            }) { return false }
            return true
        }
        if !external.isEmpty {
            MainActorWatchdog.note(
                "hasExternalChanges PASSED \(external.count)/\(paths.count): "
                + external.prefix(4).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                + "  [selfWrites=\(recentSelfWrites.count)]")
        }
        return !external.isEmpty
    }

    /// Normalise a path for comparison — resolves symlinks and the `/private`
    /// prefix so FSEvents paths and our own write paths match.
    private nonisolated static func normalize(_ path: String) -> String {
        canonical(URL(fileURLWithPath: path)).path
    }

    /// Record that the editor just saved `url`, and refresh the content-derived
    /// index (links, search, tags) from the in-memory `text` — no re-scan (the
    /// note set is unchanged) and, in the common case, no vault re-read.
    ///
    /// When the note's title and aliases are unchanged, the link graph and
    /// search entry are patched incrementally (O(1 note)). A title/alias change
    /// can alter *other* notes' backlinks, so that falls back to a debounced
    /// full rebuild for correctness.
    ///
    /// **Cross-platform, and it always had to be.** iOS carried a deliberately
    /// narrow copy of this, and the omission that mattered was the upload: iOS
    /// can open a direct-API cloud collection (Settings → Add cloud account) and
    /// `deleteNote`/`deleteFolder` already delete on the provider, so an edit
    /// that stopped at the local mirror was written, never sent, and then
    /// overwritten by the stale server copy on the next refresh or hydrate.
    /// A save is a save on both platforms; there is nothing about this body that
    /// needs AppKit.
    func noteDidSave(_ url: URL, text: String) {
        rememberSelfWrite(url)
        let title = url.deletingPathExtension().lastPathComponent

        // A cloud (RemoteStore) collection: push the saved note back to the
        // provider. The local mirror already holds the edit, so a failed upload
        // is surfaced but never loses data.
        if let remote {
            // **Never upload a file we never downloaded.** A dehydrated note is
            // a zero-byte placeholder standing in for real content on the
            // provider; writing it back would replace that content with nothing.
            // The indexers are gated too, so reaching here means something got
            // past them — which is exactly when a last line of defence earns its
            // keep.
            guard remote.isHydrated(localURL: url) else {
                report("“\(title)” hasn't been downloaded from \(remote.store.providerName) yet, so it wasn't uploaded. Open it first.")
                return
            }
            Task {
                do { try await remote.upload(localURL: url) }
                catch { report("Couldn't upload “\(title)” to \(remote.store.providerName): \(error.localizedDescription)") }
            }
        }

        // A save may never re-read the vault.
        //
        // This branch used to end in `scanOffMain()` whenever the saved note was
        // absent from the picture or its aliases had changed, and the watchdog
        // caught it happening for real: *"noteDidSave → FULL RESCAN: saved url
        // not found in notes"*. That made the failure self-amplifying — a note
        // briefly leaves the list, its next autosave re-walks 2,000 files, and
        // the walk is what makes notes leave the list. Neither condition
        // actually needs the disk re-read:
        //
        //  * absent from the picture — the file is *right there*; it was just
        //    written. Adopt it, which is O(1).
        //  * aliases changed — that alters how *other* notes' links resolve, so
        //    the derived indexes do need rebuilding. But they rebuild from
        //    index records, not from a folder walk.
        let parsedAliases = MarkdownParsing.aliases(in: text)
        let aliasesChanged = parsedAliases != search.aliases(of: url)

        guard let note = notes.first(where: { $0.fileURL == url }) ?? adopt(createdAt: url) else { return }

        // Reached only from a save, and a save is only taken once editing has
        // stopped — so this runs when the user is not typing, by construction
        // rather than by asking.
        applyDerivedUpdates(for: note, url: url, title: title,
                            text: text, aliasesChanged: aliasesChanged)
    }

    /// The post-save index work.
    private func applyDerivedUpdates(for note: Note, url: URL, title: String,
                                     text: String, aliasesChanged: Bool) {
        MainActorWatchdog.measure("noteDidSave.incremental") {
            // Cancel any in-flight debounced rebuild: it reads cache-first from a
            // pre-save mtime, so if it lands after this in-place patch it would
            // revert the just-saved note's links/tags in the index.
            deriveTask?.cancel()
            MainActorWatchdog.measure("linkGraph.updateNote") {
                linkGraph.updateNote(url: url, title: title, text: text)
            }
            MainActorWatchdog.measure("search.updateNote") {
                search.updateNote(note, text: text)
            }
            updateRelatedness(url: url, title: title, text: text)
            MainActorWatchdog.measure("embedProvider.update(\(notes.count) notes)") {
                embedProvider.update(notes: notes)   // bump so transclusions re-render
            }
            derivedRevision &+= 1
        }

        guard aliasesChanged else { return }
        MainActorWatchdog.note("noteDidSave: aliases changed — rebuilding derived indexes from records")
        // Make this note's stat current so the cache diff re-parses *it* and
        // reloads everything else from cache. Without this the record still
        // matches the pre-save mtime and the rebuild would restore the aliases
        // that were just removed. Only done here, not on every save: `notes` is
        // sorted by modification date, and re-stating on each keystroke would
        // make rows jump about under the cursor.
        restat(note, savedByteCount: text.utf8.count)
        deriveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.refreshDerived()
        }
    }

    /// Update one note's size and modification date in place, without a walk.
    private func restat(_ note: Note, savedByteCount: Int) {
        guard let index = notes.firstIndex(where: { $0.fileURL == note.fileURL }) else { return }
        notes[index] = Note(title: note.title, fileURL: note.fileURL,
                            lastModified: Date(), fileSize: savedByteCount,
                            isOnlineOnly: note.isOnlineOnly)
        notes.sort { $0.lastModified > $1.lastModified }
        revision &+= 1
    }

    // MARK: - File operations

    /// Create a new empty Markdown note and return it. The filename is derived
    /// from `title`, disambiguated if it already exists. `directory` defaults to
    /// the collection root; pass a subfolder URL to create the note there.
    @discardableResult
    /// The note's path relative to the collection root (for deep links / display).
    func relativePath(of note: Note) -> String {
        let base = rootURL.standardizedFileURL.path
        let path = note.fileURL.standardizedFileURL.path
        guard path.hasPrefix(base) else { return note.fileURL.lastPathComponent }
        return String(path.dropFirst(base.count).drop(while: { $0 == "/" }))
    }

    /// The note matching `title` (case-insensitive), or nil.
    func note(titled title: String) -> Note? {
        notes.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }
    }

    func createNote(title: String = "Untitled", in directory: URL? = nil) async -> Note? {
        let fileManager = FileManager.default
        let base = title.isEmpty ? "Untitled" : title
        let folder = directory ?? rootURL
        var candidate = folder.appendingPathComponent("\(base).md")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }

        do {
            try FileIO.create(Data(), at: candidate)
        } catch {
            report("Couldn't create the note: \(error.localizedDescription)")
            return nil
        }
        return adopt(createdAt: candidate)
    }

    /// Take a just-created file into the in-memory picture, without re-walking
    /// the folder.
    ///
    /// Creating a note changes **one** entry. This used to `await scanOffMain()`
    /// — an O(folder) walk — and the caller awaits *this*, so on a large vault
    /// the new note did not appear, and could not be selected or typed into,
    /// until the entire tree had been re-read. The walk was already off the main
    /// actor, so nothing was blocked in the CPU sense; the person was blocked,
    /// which is the only sense that counts.
    ///
    /// Then it happened twice. The write was never recorded in
    /// `recentSelfWrites`, so FSEvents reported our own new file as an external
    /// change and `reconcileSoon` ran a *second* full walk 400ms later — which
    /// republishes the whole note list and rebuilds the sidebar and outline
    /// underneath whoever is mid-way through typing the title.
    private func adopt(createdAt url: URL) -> Note? {
        // Register before anything can observe the file, so the watcher knows
        // this one was ours. `renameNote` and `append` already did this; create
        // and delete were the two that did not.
        rememberSelfWrite(url)

        let note = Note(title: url.deletingPathExtension().lastPathComponent,
                        fileURL: url,
                        lastModified: Date(),
                        fileSize: 0)
        notes.removeAll { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
        notes.append(note)
        // Same order `ScanAccumulator.sorted` uses, so an inserted note sits
        // exactly where a scan would have put it — newest first.
        notes.sort { $0.lastModified > $1.lastModified }
        revision &+= 1

        // The derived indexes take the same O(1) path a save does. The note is
        // empty, so there is nothing to parse and no file to read.
        linkGraph.updateNote(url: url, title: note.title, text: "")
        search.updateNote(note, text: "")
        embedProvider.update(notes: notes)
        derivedRevision &+= 1
        return note
    }

    /// Drop a note we just removed from the in-memory picture. See `adopt`.
    private func forget(_ note: Note) {
        rememberSelfWrite(note.fileURL)
        notes.removeAll { $0.fileURL == note.fileURL }
        revision &+= 1
        removeFromRelatedness(note.fileURL)
        embedProvider.update(notes: notes)
        derivedRevision &+= 1

        // The link graph and search index still hold the deleted note, and
        // neither offers a single-entry removal. Rebuilding is cheap (it reads
        // the cache, not the vault) — but it must not be awaited, or deleting a
        // note stalls exactly the way creating one used to.
        Task { @MainActor [weak self] in self?.refreshDerived() }
    }

    /// Rename a note's file to `newTitle` and rewrite every `[[wiki-link]]`
    /// (and `![[embed]]`) across the collection that pointed at the old title,
    /// so renaming never silently breaks links. Returns the renamed note, or
    /// `nil` if the name is empty/unchanged or the destination already exists.
    @discardableResult
    func renameNote(_ note: Note, to newTitle: String) async -> Note? {
        let title = newTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !title.isEmpty, title != note.title else { return nil }

        let destination = note.fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(title).md")
        // A case-only rename ("todo" → "Todo") resolves to the *same* file on the
        // case-insensitive default volume, so `fileExists` sees the note itself —
        // allow it through rather than reporting a spurious "already exists".
        let sameFile = destination.standardizedFileURL.path.lowercased()
            == note.fileURL.standardizedFileURL.path.lowercased()
        guard sameFile || !FileManager.default.fileExists(atPath: destination.path) else {
            report("A note named “\(title)” already exists in this folder.")
            return nil
        }
        do {
            try FileManager.default.moveItem(at: note.fileURL, to: destination)
        } catch {
            report("Couldn't rename the note: \(error.localizedDescription)")
            return nil
        }

        bookmarks.updatePath(from: note.fileURL, to: destination)   // keep the pin

        // Which notes actually mention this one — asked *before* adopting, while
        // the graph still keys the note by its old URL.
        let candidates = wikiLinkRewriteCandidates(for: note.fileURL, movedTo: destination)
        let moved = adopt(renamed: note, to: destination, title: title)

        // The rename is complete the moment the file has moved and the picture
        // has adopted it. Rewriting other notes' `[[links]]` is bookkeeping that
        // follows, and the user must not be made to wait for it: on a 2,000-note
        // vault this call took **13.3 seconds** measured end-to-end, and naming
        // a new note *is* a rename, so that was the cost of typing a title.
        Task { [weak self] in
            await self?.rewriteWikiLinks(from: note.title, to: title, in: candidates)
        }
        return moved
    }

    /// The notes whose `[[links]]` a rename of `oldURL` could invalidate.
    ///
    /// The link graph already knows this exactly — it is the backlink set — so
    /// the rewrite reads a handful of files instead of the whole vault. If the
    /// graph has not been built yet there is nothing to ask, and correctness
    /// beats speed: fall back to every note.
    private func wikiLinkRewriteCandidates(for oldURL: URL, movedTo newURL: URL) -> [URL] {
        guard !linkGraph.outgoingByURL.isEmpty else {
            return notes.map { $0.fileURL == oldURL ? newURL : $0.fileURL }
        }
        return (linkGraph.backlinksByURL[oldURL] ?? []).map { $0 == oldURL ? newURL : $0 }
    }

    /// Move a renamed note within the in-memory picture, without re-walking.
    ///
    /// This is the one that hurt most in practice. A new note opens with its
    /// title focused, so *naming* a note is a rename — and a rename moved the
    /// file, registered neither the old path nor the new one, then awaited a
    /// full walk while FSEvents queued a second one for the two paths it had
    /// not been told about. Naming a note in a large vault therefore re-read
    /// the entire vault twice, the second time landing mid-keystroke.
    private func adopt(renamed note: Note, to destination: URL, title: String) -> Note? {
        let now = Date()
        rememberSelfWrite(note.fileURL, at: now)      // the file that left
        rememberSelfWrite(destination, at: now)       // and the one that arrived

        // Keep `lastModified` — a move preserves it, and inventing a new one
        // would jump the note to the top of a list sorted by it, on nothing
        // more than a rename.
        let moved = Note(title: title, fileURL: destination,
                         lastModified: note.lastModified, fileSize: note.fileSize,
                         isOnlineOnly: note.isOnlineOnly)
        notes.removeAll { $0.fileURL == note.fileURL || $0.fileURL == destination }
        notes.append(moved)
        notes.sort { $0.lastModified > $1.lastModified }
        revision &+= 1
        embedProvider.update(notes: notes)
        derivedRevision &+= 1

        // A rename rewrites `[[links]]` in *other* notes, so the graph and
        // search index do need rebuilding — but off the caller's back. The
        // rebuild reads the index cache, not the vault.
        reindexSoon()
        return moved
    }

    /// Rebuild the derived indexes without making anyone wait for it.
    ///
    /// Deliberately not `await`ed anywhere: every caller is a user action that
    /// has already happened on disk, and none of them should be gated on
    /// re-deriving an index.
    private func reindexSoon() {
        Task { @MainActor [weak self] in self?.refreshDerived() }
    }

    /// Duplicate a note beside the original ("Title copy.md", disambiguated)
    /// and return the copy.
    @discardableResult
    func duplicateNote(_ note: Note) async -> Note? {
        let folder = note.fileURL.deletingLastPathComponent()
        let base = "\(note.title) copy"
        var candidate = folder.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: note.fileURL, to: candidate)
        } catch {
            report("Couldn't duplicate the note: \(error.localizedDescription)")
            return nil
        }
        // The copy carries content, so unlike a fresh note it needs indexing —
        // but in the background, like every other one-file change here.
        let copy = adopt(createdAt: candidate)
        reindexSoon()
        return copy
    }

    /// Rewrite `[[oldTitle]]`, `[[oldTitle|alias]]`, `[[oldTitle#heading]]` and
    /// their `![[…]]` embed forms to the new title in every note — including the
    /// renamed note itself, whose file has already moved to `movedTo`.
    /// Case-insensitive and whitespace-tolerant; aliases and headings survive.
    private func rewriteWikiLinks(from oldTitle: String, to newTitle: String,
                                  in urls: [URL]) async {
        guard !urls.isEmpty else { return }
        // Read + rewrite the candidates off the main actor — it's file I/O.
        // Collect the notes we couldn't rewrite so the shell can tell the user
        // exactly which links may now be stale, rather than failing silently.
        let outcome: (written: [URL], failed: [String]) = await offMain {
            let escaped = NSRegularExpression.escapedPattern(for: oldTitle)
            guard let regex = try? NSRegularExpression(
                pattern: #"(\[\[)\s*"# + escaped + #"\s*(?=[#|\]])"#,
                options: [.caseInsensitive]
            ) else { return ([], []) }
            let template = "$1" + NSRegularExpression.escapedTemplate(for: newTitle)
            var written: [URL] = []
            var failed: [String] = []
            for url in urls {
                guard let text = try? FileIO.readString(at: url),
                      text.contains("[[") else { continue }
                let range = NSRange(text.startIndex..., in: text)
                guard regex.firstMatch(in: text, options: [], range: range) != nil else { continue }
                let updated = regex.stringByReplacingMatches(in: text, options: [], range: range,
                                                             withTemplate: template)
                do {
                    try FileIO.write(Data(updated.utf8), to: url)
                    written.append(url)
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            return (written, failed)
        }

        // Register these writes as our own so the change watcher doesn't re-scan
        // them as external changes (a spurious reconcile + double re-index).
        let now = Date()
        for url in outcome.written { rememberSelfWrite(url, at: now) }

        let failures = outcome.failed
        if !failures.isEmpty {
            let list = failures.prefix(5).joined(separator: ", ")
            let more = failures.count > 5 ? " and \(failures.count - 5) more" : ""
            report("Renamed the note, but couldn't update links in \(failures.count) note\(failures.count == 1 ? "" : "s") (\(list)\(more)). Those links may now be broken.")
        }
    }

    /// Return the note at `relativePath`, creating the file (and any intermediate
    /// folders) with `content` if it doesn't exist yet. Used for daily notes.
    @discardableResult
    func note(atRelativePath relativePath: String, creatingWith content: @autoclosure () -> String) async -> Note? {
        let url = rootURL.appendingPathComponent(relativePath)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileIO.create(Data(content().utf8), at: url)
            } catch {
                report("Couldn't create “\(relativePath)”: \(error.localizedDescription)")
                return nil
            }
            await scanOffMain()
            refreshDerived()
        }
        return notes.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// Append `text` to a note's file on disk (quick-capture / daily-note intents).
    func append(_ text: String, to note: Note) async {
        // Read, join and write in one hop off the main actor — both file calls
        // are coordinated, so both can block on a provider.
        let url = note.fileURL
        let outcome = await offMain { () -> Result<String, Error>? in
            guard let existing = try? FileIO.readString(at: url) else { return nil }
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let updated = existing + separator + text
            do { try FileIO.write(Data(updated.utf8), to: url); return .success(updated) }
            catch { return .failure(error) }
        }
        guard let outcome else { return }
        let updated: String
        switch outcome {
        case .success(let value): updated = value
        case .failure(let error):
            report("Couldn't append to “\(note.title)”: \(error.localizedDescription)")
            return
        }
        rememberSelfWrite(url)
        // **One note's content changed, so no walk.** This used to
        // `await scanOffMain()`, which made a one-file append cost a re-read of
        // the whole folder — and appending is what quick-capture does.
        noteDidSave(url, text: updated)
    }

    /// Move a note to the Trash (never a hard delete) and re-index.
    func deleteNote(_ note: Note) async {
        // Capture the remote path *before* trashing (the mapping is by URL).
        let remotePath = remote.map { $0.remotePath(forLocalURL: note.fileURL) }
        // `Trash.item` throws only when the file is still there, so a thrown
        // error is the one case where dropping it from the model would be a
        // lie. It used to call `trashItem` directly, report the throw, and
        // `forget(note)` anyway — which on iOS (no Trash for an app container)
        // removed the note from the sidebar, left it on disk, and let the next
        // scan bring it back.
        do {
            try Trash.item(at: note.fileURL)
        } catch {
            report("Couldn't delete “\(note.title)”: \(error.localizedDescription)")
            return
        }
        // A direct-API collection must delete on the provider too, or the next
        // syncDown silently re-downloads the note the user just deleted.
        if let remote, let remotePath {
            do { try await remote.store.delete(path: remotePath) }
            catch { report("Couldn't delete “\(note.title)” on \(remote.store.providerName): \(error.localizedDescription)") }
        }
        forget(note)
    }

    /// Create an empty folder inside `parent` (defaults to the root), with the
    /// name disambiguated if it already exists. Returns the new folder's URL.
    @discardableResult
    func createFolder(named name: String = "New Folder", in parent: URL? = nil) async -> URL? {
        let base = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !base.isEmpty else { return nil }
        let container = parent ?? rootURL
        var candidate = container.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = container.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        } catch {
            report("Couldn't create the folder: \(error.localizedDescription)")
            return nil
        }
        await scanOffMain()
        refreshDerived()
        return candidate
    }

    /// Move a folder (and its contents) to the Trash and re-index.
    func deleteFolder(at url: URL) async {
        let remotePath = remote.map { $0.remotePath(forLocalURL: url) }
        do {
            try Trash.item(at: url)
        } catch {
            report("Couldn't delete the folder: \(error.localizedDescription)")
            return
        }
        if let remote, let remotePath {
            do { try await remote.store.delete(path: remotePath) }
            catch { report("Couldn't delete the folder on \(remote.store.providerName): \(error.localizedDescription)") }
        }
        await scanOffMain()
        refreshDerived()
    }

    /// Move a note or attachment file into `folder` (which must be inside the
    /// collection). Returns the item's new URL, or `nil` when the move fails or
    /// a same-named item already exists there.
    func moveItem(at itemURL: URL, into folder: URL) async -> URL? {
        let destination = folder.appendingPathComponent(itemURL.lastPathComponent)
        guard destination.standardizedFileURL != itemURL.standardizedFileURL else { return nil }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            report("“\(itemURL.lastPathComponent)” already exists in that folder.")
            return nil
        }
        do {
            try FileManager.default.moveItem(at: itemURL, to: destination)
        } catch {
            report("Couldn't move “\(itemURL.lastPathComponent)”: \(error.localizedDescription)")
            return nil
        }
        bookmarks.updatePath(from: itemURL, to: destination)   // keep the pin
        await scanOffMain()
        refreshDerived()
        return destination
    }
}

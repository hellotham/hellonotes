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

    /// Whether non-Markdown files are collected at all. Gates the *walk*, not
    /// the display: on a folder of a hundred thousand documents, not reading
    /// their names is the entire point. (Phase 5 wires this to a menu item.)
    var showsNonNoteFiles = true

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
    private func report(_ message: String) { lastError = message }

    /// Renders `![[Note]]` transclusions to inline images (cross-platform: the
    /// live editor's block-embed renderer uses it on both macOS and iOS).
    let embedProvider = CollectionEmbedProvider()

    #if os(macOS)
    private var fileWatcher: FileWatcher?

    /// Standardised paths this collection wrote itself, with when — so the file
    /// watcher can ignore the churn from our own autosaves (and their atomic
    /// temp files) instead of re-scanning the whole collection on every save.
    private var recentSelfWrites: [String: Date] = [:]

    /// Coalesces bursts of external changes (a co-editing app like Obsidian
    /// autosaving, or iCloud streaming a file down in pieces) into a single
    /// scan + reconcile, instead of re-walking the whole vault per event.
    private var externalReconcileTask: Task<Void, Never>?

    /// Debounced index refresh scheduled after an editor save (the note *set*
    /// is unchanged, so no re-scan is needed — only the content-derived index).
    private var deriveTask: Task<Void, Never>?

    /// Coalesces `.git` churn into one status read (a checkout touches hundreds
    /// of files in there).
    private var gitRefreshTask: Task<Void, Never>?
    #endif

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

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.id = rootURL.standardizedFileURL.path
        git.rootURL = rootURL
        bookmarks.load(rootURL: rootURL)
    }

    // MARK: - Scanning

    /// Enumerate `rootURL` into notes / attachments / folders. `nonisolated` and
    /// pure so it can run on a background executor — a full directory walk of a
    /// large collection is thousands of `stat` calls that shouldn't block the UI.
    nonisolated static func enumerate(_ rootURL: URL) -> (notes: [Note], attachments: [CollectionFile], folders: [URL]) {
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
            if Task.isCancelled { return ([], [], []) }
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
    func scan() {
        if let reason = Self.unavailability(of: rootURL) { markUnavailable(reason); return }
        apply(Self.enumerate(rootURL))
    }

    /// Adopt a scan's results. The **only** place the note set is replaced, so
    /// that "we looked and the folder was unreadable" can never be mistaken for
    /// "we looked and the folder was empty".
    private func apply(_ result: (notes: [Note], attachments: [CollectionFile], folders: [URL])) {
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
        let collectionID = id
        let source = LocalTreeSource(root: rootURL, includesNonNoteFiles: showsNonNoteFiles)
        let resume = Self.resumePoint(for: collectionID)

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

        let (batches, continuation) = AsyncStream<WalkBatch>.makeStream()
        let walk = Task.detached(priority: .userInitiated) { () -> WalkResult in
            defer { continuation.finish() }
            return await ResumableTreeWalk.run(
                source: source,
                resuming: resume,
                onCheckpoint: { WalkCheckpointStore.save($0, for: collectionID) },
                onBatch: { continuation.yield($0) })
        }
        currentScan = walk

        var found = ScanAccumulator()
        let result = await withTaskCancellationHandler {
            var lastPublished = Date.distantPast
            for await batch in batches {
                found.add(batch)
                scanProgress = batch.progress
                // Publishing rebuilds the outline, so throttle it rather than
                // paying that per directory.
                if isFirstPicture, Date().timeIntervalSince(lastPublished) > 0.15 {
                    lastPublished = Date()
                    publish(found)
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

        // **Our own cancellation outranks the walk's verdict.** Iterating an
        // AsyncStream ends when the *consuming* task is cancelled, so the loop
        // above can stop early while the detached walk goes on to finish and
        // report `isComplete`. Publishing the accumulator then would replace the
        // note list with however little arrived before we stopped listening —
        // which is how a cancelled rescan emptied a collection outright.
        let sawWholeTree = result.isComplete && !Task.isCancelled

        if sawWholeTree {
            publish(found)
            state = isAvailable ? .ready : state
            WalkCheckpointStore.rememberTotal(result.progress.directoriesVisited, for: collectionID)
        } else {
            // A partial pass. Show it only if there was nothing better, and say
            // the list is a subset either way so search can disclose it.
            if isFirstPicture { publish(found) }
            markStale(.scanIncomplete)
        }
    }

    /// Where to resume from, or a fresh start that still remembers how big the
    /// tree was last time (which is what makes the second scan's bar real).
    private static func resumePoint(for collectionID: String) -> WalkCheckpoint? {
        guard let stored = WalkCheckpointStore.load(for: collectionID) else { return nil }
        guard stored.frontier.isEmpty else { return stored }
        return WalkCheckpoint(frontier: [""], directoriesVisited: 0, itemsSeen: 0,
                              previousTotalDirectories: stored.previousTotalDirectories)
    }

    /// Accumulates a walk's batches into the collection's three lists.
    private struct ScanAccumulator {
        private var notes: [Note] = []
        private var files: [CollectionFile] = []
        private var folders: [URL] = []

        mutating func add(_ batch: WalkBatch) {
            for child in batch.children {
                if child.isDirectory { folders.append(child.url); continue }
                if child.isMarkdown {
                    notes.append(Note(title: child.url.deletingPathExtension().lastPathComponent,
                                      fileURL: child.url,
                                      lastModified: child.modified,
                                      fileSize: child.size,
                                      isOnlineOnly: child.isOnlineOnly))
                } else {
                    files.append(CollectionFile(url: child.url, lastModified: child.modified))
                }
            }
        }

        var sorted: (notes: [Note], attachments: [CollectionFile], folders: [URL]) {
            (notes.sorted { $0.lastModified > $1.lastModified },
             files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
             folders)
        }
    }

    private func publish(_ found: ScanAccumulator) {
        apply(found.sorted)
    }

    // MARK: - Lifecycle

    #if os(macOS)
    /// Begin the security scope, do an initial scan, refresh derived data and Git
    /// status, and start watching the folder for external changes.
    func activate(onExternalChange: @escaping @MainActor () -> Void) async {
        securityScoped = rootURL.startAccessingSecurityScopedResource()
        await scanOffMain()
        refreshDerived()
        await git.refreshStatus()
        startWatching(onExternalChange: onExternalChange)
    }

    /// Stop watching and relinquish the security scope. Call before closing.
    func deactivate() {
        fileWatcher?.stop()
        fileWatcher = nil
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
                    } else if FileIO.isMaterialized(at: note.fileURL),
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

            linkGraph.load(pairs: pairs)
            await search.load(pairs: pairs)
            derivedRevision &+= 1
        }
    }

    /// Rebuild everything from scratch, ignoring the index cache — the safety
    /// valve for when the index ever looks wrong.
    func rescan() {
        CollectionIndexCache.remove(for: rootURL)
        Task {
            await scanOffMain()
            refreshDerived(force: true)
        }
    }

    private func startWatching(onExternalChange: @escaping @MainActor () -> Void) {
        let watcher = FileWatcher { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, onExternalChange: onExternalChange)
            }
        }
        watcher.start(url: rootURL)
        fileWatcher = watcher
    }

    /// Turn what FSEvents said into what the collection should do about it.
    private func handle(_ event: FileWatcherEvent,
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
            // FSEvents is telling us its own change list is incomplete. Nothing
            // short of a full rescan can be trusted after this, and until that
            // lands the index is admittedly behind — which search must disclose.
            markStale(.eventsDropped)
            reconcileSoon(onExternalChange: onExternalChange)

        case .itemsChanged(let paths):
            // `.git` churn is not a *content* change — `hasExternalChanges`
            // rightly filters it out, or every auto-commit would re-scan the
            // vault. But it is still news: an external `git pull`, checkout or
            // rebase moves the branch and the change count, and the status bar
            // would otherwise go on asserting the old ones indefinitely.
            if paths.contains(where: Self.isGitMetadata) { refreshGitSoon() }
            guard hasExternalChanges(in: paths) else { return }
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

    /// Debounced rescan + reindex.
    ///
    /// A live co-editor (Obsidian) plus iCloud can rewrite files in rapid
    /// bursts. Without coalescing, each event drove a full off-main vault scan +
    /// index rebuild + editor reconcile — which, while the open note is being
    /// co-edited, stutters the UI and keeps resetting the editor's scroll
    /// position.
    private func reconcileSoon(onExternalChange: @escaping @MainActor () -> Void) {
        externalReconcileTask?.cancel()
        externalReconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
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

    /// Whether `paths` contains a change we didn't cause. Filters out our own
    /// recent autosaves and hidden-file churn (atomic-write temp files, the
    /// `.git` directory that auto-commit touches, `.DS_Store`), so the app's own
    /// writes never trigger a full re-scan + re-index of the collection.
    private func hasExternalChanges(in paths: [String]) -> Bool {
        let now = Date()
        recentSelfWrites = recentSelfWrites.filter { now.timeIntervalSince($0.value) < 5 }
        return paths.contains { path in
            if (path as NSString).lastPathComponent.hasPrefix(".") { return false }
            if let wroteAt = recentSelfWrites[Self.normalize(path)],
               now.timeIntervalSince(wroteAt) < 3 { return false }
            return true
        }
    }

    /// Normalise a path for comparison — resolves symlinks and the `/private`
    /// prefix so FSEvents paths and our own write paths match.
    private nonisolated static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Record that the editor just saved `url`, and refresh the content-derived
    /// index (links, search, tags) from the in-memory `text` — no re-scan (the
    /// note set is unchanged) and, in the common case, no vault re-read.
    ///
    /// When the note's title and aliases are unchanged, the link graph and
    /// search entry are patched incrementally (O(1 note)). A title/alias change
    /// can alter *other* notes' backlinks, so that falls back to a debounced
    /// full rebuild for correctness.
    func noteDidSave(_ url: URL, text: String) {
        recentSelfWrites[Self.normalize(url.path)] = Date()
        let title = url.deletingPathExtension().lastPathComponent

        // A cloud (RemoteStore) collection: push the saved note back to the
        // provider. The local mirror already holds the edit, so a failed upload
        // is surfaced but never loses data.
        if let remote {
            Task {
                do { try await remote.upload(localURL: url) }
                catch { report("Couldn't upload “\(title)” to \(remote.store.providerName): \(error.localizedDescription)") }
            }
        }

        if let note = notes.first(where: { $0.fileURL == url }),
           MarkdownParsing.aliases(in: text) == search.aliases(of: url) {
            // Cancel any in-flight debounced rebuild: it reads cache-first from a
            // pre-save mtime, so if it lands after this in-place patch it would
            // revert the just-saved note's links/tags in the index.
            deriveTask?.cancel()
            linkGraph.updateNote(url: url, title: title, text: text)
            search.updateNote(note, text: text)
            embedProvider.update(notes: notes)   // bump so transclusions re-render
            derivedRevision &+= 1
        } else {
            deriveTask?.cancel()
            deriveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                // Re-stat first: the cache diff compares against each note's
                // scanned mtime/size, and this save just changed them on disk —
                // without a fresh scan the edited note would look unchanged and
                // its stale cached metadata would reload.
                await self.scanOffMain()
                self.refreshDerived()
            }
        }
    }
    #else
    /// iOS's stand-in for the macOS file watcher.
    private var presenter: DirectoryPresenter?
    /// Coalesces a burst of coordinated change callbacks into one rescan.
    private var externalReconcileTask: Task<Void, Never>?

    func activate(onExternalChange: @escaping @MainActor () -> Void) async {
        securityScoped = rootURL.startAccessingSecurityScopedResource()
        await scanOffMain()
        embedProvider.update(notes: notes)   // resolve `![[Note]]` transclusions
        Task { await search.refresh(from: notes) }
        startPresenting(onExternalChange: onExternalChange)
    }

    func deactivate() {
        presenter?.stop()
        presenter = nil
        if securityScoped { rootURL.stopAccessingSecurityScopedResource(); securityScoped = false }
    }

    /// iOS has no FSEvents, so until now it had **no change detection at all**:
    /// an iPad showing a vault edited on a Mac stayed stale until relaunch. A
    /// file-coordination presenter is the portable substitute — coarser than
    /// FSEvents (no flags, no path list), so it maps onto a plain debounced
    /// rescan and claims nothing more.
    private func startPresenting(onExternalChange: @escaping @MainActor () -> Void) {
        presenter?.stop()
        let presenter = DirectoryPresenter(root: rootURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconcileSoon(onExternalChange: onExternalChange)
            }
        }
        presenter.start()
        self.presenter = presenter
    }

    /// Debounced rescan, shared with the macOS watcher's reasoning: a device
    /// syncing a vault down rewrites files in bursts, and one rescan per file
    /// would spend the whole burst re-walking.
    private func reconcileSoon(onExternalChange: @escaping @MainActor () -> Void) {
        externalReconcileTask?.cancel()
        externalReconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.scanOffMain()
            self.refreshDerived()
            onExternalChange()
        }
    }

    func refreshDerived() {
        embedProvider.update(notes: notes)
        Task { await search.refresh(from: notes) }
    }
    #endif

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

        await scanOffMain()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == candidate.standardizedFileURL }
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
        await rewriteWikiLinks(from: note.title, to: title, renamed: note.fileURL, movedTo: destination)
        await scanOffMain()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == destination.standardizedFileURL }
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
        await scanOffMain()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == candidate.standardizedFileURL }
    }

    /// Rewrite `[[oldTitle]]`, `[[oldTitle|alias]]`, `[[oldTitle#heading]]` and
    /// their `![[…]]` embed forms to the new title in every note — including the
    /// renamed note itself, whose file has already moved to `movedTo`.
    /// Case-insensitive and whitespace-tolerant; aliases and headings survive.
    private func rewriteWikiLinks(from oldTitle: String, to newTitle: String,
                                  renamed oldURL: URL, movedTo newURL: URL) async {
        // `notes` is pre-rescan, so the renamed note still lists its old URL.
        let urls = notes.map { $0.fileURL == oldURL ? newURL : $0.fileURL }
        // Read + rewrite every note off the main actor — it's O(N) file I/O.
        // Collect the notes we couldn't rewrite so the shell can tell the user
        // exactly which links may now be stale, rather than failing silently.
        let outcome: (written: [URL], failed: [String]) = await Task.detached(priority: .userInitiated) {
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
        }.value

        // Register these writes as our own so the file watcher doesn't re-scan
        // them as external changes (a spurious reconcile + double re-index).
        // The watcher + self-write filtering are macOS-only.
        #if os(macOS)
        let now = Date()
        for url in outcome.written { recentSelfWrites[Self.normalize(url.path)] = now }
        #endif

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
        guard let existing = try? FileIO.readString(at: note.fileURL) else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        do { try FileIO.write(Data((existing + separator + text).utf8), to: note.fileURL) }
        catch { report("Couldn't append to “\(note.title)”: \(error.localizedDescription)"); return }
        #if os(macOS)
        recentSelfWrites[Self.normalize(note.fileURL.path)] = Date()
        #endif
        await scanOffMain()
        refreshDerived()
    }

    /// Move a note to the Trash (never a hard delete) and re-index.
    func deleteNote(_ note: Note) async {
        // Capture the remote path *before* trashing (the mapping is by URL).
        let remotePath = remote.map { $0.remotePath(forLocalURL: note.fileURL) }
        do {
            try FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
        } catch {
            report("Couldn't move “\(note.title)” to the Trash: \(error.localizedDescription)")
        }
        // A direct-API collection must delete on the provider too, or the next
        // syncDown silently re-downloads the note the user just deleted.
        if let remote, let remotePath {
            do { try await remote.store.delete(path: remotePath) }
            catch { report("Couldn't delete “\(note.title)” on \(remote.store.providerName): \(error.localizedDescription)") }
        }
        await scanOffMain()
        refreshDerived()
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
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            report("Couldn't move the folder to the Trash: \(error.localizedDescription)")
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

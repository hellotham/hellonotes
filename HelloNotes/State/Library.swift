//
//  Library.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//

import Foundation

#if os(macOS)
import AppKit
#endif

/// The workspace: several `Collection`s open at once. The library tracks which
/// collection is *focused* (the one the editor, Git panel, and note-level
/// actions operate on) and persists the set of open collections so they reopen
/// on the next launch. Collections themselves stay isolated — the library only
/// aggregates them for library-wide search and reopening.
@MainActor
@Observable
final class Library {
    /// The collections currently open, in the order they were added.
    private(set) var collections: [Collection] = []

    /// The focused collection's id — drives the editor, Git panel and
    /// note-scoped actions. Defaults to the first collection.
    var focusedID: Collection.ID?

    /// The focused collection (falls back to the first open one).
    var focused: Collection? {
        collections.first { $0.id == focusedID } ?? collections.first
    }

    // Cached flattened notes + id→note index, rebuilt only when a collection's
    // structural `revision` changes. `allNotes` used to re-`flatMap` every open
    // collection on each access (read many times per view body), and callers
    // then linearly scanned it to resolve the selected note.
    @ObservationIgnored private var cachedRevision = -1
    @ObservationIgnored private var cachedAllNotes: [Note] = []
    @ObservationIgnored private var cachedIndex: [Note.ID: Note] = [:]

    /// Sum of collection revisions (+ count) — cheap, changes on any note-set change.
    private var aggregateRevision: Int {
        collections.reduce(collections.count) { $0 &+ $1.revision }
    }

    private func refreshCacheIfNeeded() {
        let rev = aggregateRevision
        guard rev != cachedRevision else { return }
        cachedRevision = rev
        var all: [Note] = []
        var index: [Note.ID: Note] = [:]
        for collection in collections {
            all.append(contentsOf: collection.notes)
            for note in collection.notes { index[note.id] = note }
        }
        cachedAllNotes = all
        cachedIndex = index
    }

    /// Notes across every open collection (for library-wide search / chat).
    var allNotes: [Note] {
        refreshCacheIfNeeded()
        return cachedAllNotes
    }

    /// O(1) lookup of a note by id across all collections.
    func note(id: Note.ID?) -> Note? {
        guard let id else { return nil }
        refreshCacheIfNeeded()
        return cachedIndex[id]
    }

    var isEmpty: Bool { collections.isEmpty }

    /// Called when any open collection changes on disk — wired by the view to
    /// reconcile open editors and revalidate the selection.
    var onExternalChange: @MainActor () -> Void = {}

    /// Called with a collection's root URL each time it's opened — wired to the
    /// recents store.
    var onOpened: @MainActor (URL) -> Void = { _ in }

    /// A note another window (graph, mind map, assistant, chat) asked the main
    /// window to select. The main window observes this, selects the note, and
    /// clears it.
    var pendingOpenNoteID: Note.ID?

    /// Ask the main window to select and show `noteID`.
    func requestOpen(_ noteID: Note.ID) { pendingOpenNoteID = noteID }

    /// A collection the main window has been asked to *show*. Unlike a change of
    /// `focusedID`, this moves the sidebar even when it is parked on the Library
    /// place, and scrolls the collection's row into view: it is set only when the
    /// user did something that means "take me there" — adding a cloud folder,
    /// say — and a collection added out of sight reads as one that wasn't added.
    var pendingRevealCollectionID: Collection.ID?

    func requestReveal(_ collectionID: Collection.ID) { pendingRevealCollectionID = collectionID }

    /// A question the Ask Library window should open pre-filled with — set when
    /// someone selects a phrase and asks the library about it. Consumed once,
    /// by the window, so reopening it later doesn't re-ask a stale question.
    var pendingLibraryQuestion: String?

    func requestAsk(_ question: String) { pendingLibraryQuestion = question }

    /// Take the pending question, if any, clearing it.
    func takePendingLibraryQuestion() -> String? {
        defer { pendingLibraryQuestion = nil }
        return pendingLibraryQuestion
    }

    // MARK: - Focus

    func focus(_ collection: Collection) { focusedID = collection.id }

    /// The collection that contains `fileURL`, if any (matched by path prefix).
    func collection(containing fileURL: URL) -> Collection? {
        let path = fileURL.standardizedFileURL.path
        return collections.first { collection in
            // `collection.id` is the already-standardised root path — reuse it
            // instead of re-standardising the root on each of the many calls.
            let base = collection.id
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// Focus the collection owning `fileURL` (used when a note is selected).
    func focusCollection(containing fileURL: URL) {
        if let owner = collection(containing: fileURL) { focusedID = owner.id }
    }

    // MARK: - Open / close

    /// Open the folder at `url` as a collection (or focus it if already open),
    /// activate it, and remember it for next launch. Returns the collection.
    @discardableResult
    func open(url: URL) async -> Collection {
        let id = url.standardizedFileURL.path
        if let existing = collections.first(where: { $0.id == id }) {
            focusedID = existing.id
            onOpened(url)
            return existing
        }
        let collection = Collection(rootURL: url)
        collections.append(collection)
        focusedID = collection.id
        await collection.activate(onExternalChange: { [weak self] in self?.onExternalChange() })
        persist()
        onOpened(url)
        return collection
    }

    /// Open several folders at once (multi-select).
    func open(urls: [URL]) async {
        for url in urls { await open(url: url) }
    }

    /// Open a cloud account (a `RemoteStore` folder) as a first-class collection:
    /// mirror it into a local cache, then open that cache with the normal
    /// machinery. Saved edits upload back through `Collection.remote`.
    ///
    /// The collection is created and focused **before** the sync runs, not
    /// after. Waiting for a whole-account download to finish before showing
    /// anything is why "Add as Collection" looked dead: on a real account
    /// nothing appeared for minutes, and one failed request then discarded even
    /// the folders that had already synced. Now the collection is there
    /// immediately and fills in as the sync proceeds (its own file watcher
    /// picks up each downloaded note), and a failure leaves what did arrive.
    @discardableResult
    func openRemote(
        store: RemoteStore, remoteRoot: String, displayName: String,
        progress: @escaping @Sendable (RemoteSyncProgress) -> Void = { _ in }
    ) async throws -> RemoteSyncOutcome {
        let mirror = RemoteMirror(
            store: store,
            cacheRoot: RemoteMirror.cacheDirectory(provider: store.providerName,
                                                   folder: remoteRoot.isEmpty ? displayName : remoteRoot),
            remoteRoot: remoteRoot,
            displayName: displayName)
        // The cache directory has to exist before a Collection can be opened on
        // it; this also fails fast (and visibly) if the container is unwritable.
        try FileManager.default.createDirectory(at: mirror.cacheRoot, withIntermediateDirectories: true)

        let id = mirror.cacheRoot.standardizedFileURL.path
        if let existing = collections.first(where: { $0.id == id }) {
            existing.remote = mirror
            focusedID = existing.id
        } else {
            let collection = Collection(rootURL: mirror.cacheRoot)
            collection.remote = mirror
            collections.append(collection)
            focusedID = collection.id
            await collection.activate(onExternalChange: { [weak self] in self?.onExternalChange() })
        }

        // Show it before the sync, not after: the collection exists now, and the
        // point of revealing it is to prove the add worked while the sync runs.
        requestReveal(id)
        persist()

        // Metadata first: the folder's *shape* arrives immediately and content
        // is fetched when something needs it. `syncDown` downloaded every note
        // before showing anything, which is fine for a notes vault and hopeless
        // for an account of any size — and it skipped non-Markdown files
        // entirely, so a folder of PDFs mirrored to an empty collection.
        let outcome = try await mirror.syncMetadata(progress: progress)
        if let collection = collections.first(where: { $0.id == id }) {
            await collection.scanOffMain()
            collection.refreshDerived()
        }
        return outcome
    }

    /// Close a collection: stop watching it, drop it, and update persistence.
    func close(_ collection: Collection) {
        collection.deactivate()
        collections.removeAll { $0.id == collection.id }
        if focusedID == collection.id { focusedID = collections.first?.id }
        persist()
    }

    /// Close every open collection (used when switching to a saved library).
    func closeAll() {
        for collection in collections { collection.deactivate() }
        collections.removeAll()
        focusedID = nil
        persist()
    }

    /// Switch to a saved library: close what's open, then open its collections.
    func openLibrary(_ urls: [URL]) async {
        closeAll()
        await open(urls: urls)
    }

    #if os(macOS)
    /// Present an open panel (multi-select) to add one or more collections.
    func requestOpenCollections() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more folders to open as collections."

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await openChecking(urls) }
    }

    /// Add a folder from a cloud provider that is already mounted on this Mac.
    ///
    /// This is the path that should be tried *first*, and it is the cheapest
    /// thing in the whole cloud story: Box, Dropbox, OneDrive and Google Drive
    /// mount their storage at `~/Library/CloudStorage/<Provider>` as ordinary
    /// dataless files, so a collection there needs **no sign-in, no token, no
    /// cache and no sync engine**. Everything that makes cloud files work —
    /// coordinated reads that materialise on demand, online-only badges,
    /// indexers that skip un-downloaded notes, Download / Remove Download —
    /// already applies, because to the app it is simply a folder.
    ///
    /// The sandbox cannot *list* that directory, but the panel runs out of
    /// process and can, and the user's selection is what grants access.
    func requestOpenCloudFolder() {
        let installed = CloudProvider.installedClients()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.directoryURL = CloudProvider.cloudStorageDirectory
        panel.message = installed.isEmpty
            ? "Choose a folder from a cloud provider mounted on this Mac."
            : "Choose a folder from \(installed.map(\.name).formatted(.list(type: .and))) "
                + "— no sign-in needed, the files are already on this Mac."

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await openChecking(urls) }
    }

    /// Open `urls`, pausing to warn about any that look big enough to take a
    /// while. Adding a huge folder is never *blocked* — it is the user's folder
    /// and their call. The warning exists so the wait isn't a surprise, and so
    /// the far more common intent ("I meant my Notes subfolder") has somewhere
    /// to go.
    private func openChecking(_ urls: [URL]) async {
        for url in urls {
            let estimate = await Self.estimateSize(of: url)
            guard estimate.looksLarge else { await open(url: url); continue }
            switch Self.confirmLargeFolder(url, estimate: estimate) {
            case .addAnyway:
                await open(url: url)
            case .chooseSubfolder:
                if let chosen = Self.chooseSubfolder(under: url) { await openChecking([chosen]) }
            case .cancel:
                continue
            }
        }
    }

    /// What a one-second look at a folder suggests about its size.
    struct FolderSizeEstimate: Sendable {
        var itemsSeen = 0
        var directoriesRemaining = 0
        /// The probe walked the *whole* tree inside its budget — so whatever it
        /// counted is the real total, however large.
        var isComplete = false

        /// No magic threshold on a number we can't know in advance: the signal
        /// is that a full second wasn't enough to finish *and* there is already
        /// a lot here.
        var looksLarge: Bool { !isComplete && itemsSeen >= 5_000 }
    }

    /// Walk for at most `budget` seconds and report what was found.
    static func estimateSize(of url: URL, budget: TimeInterval = 1.0) async -> FolderSizeEstimate {
        let source = LocalTreeSource(root: url)
        let walk = Task.detached(priority: .userInitiated) {
            await ResumableTreeWalk.run(source: source) { _ in }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(budget))
            walk.cancel()
        }
        let result = await walk.value
        deadline.cancel()
        return FolderSizeEstimate(itemsSeen: result.progress.itemsSeen,
                                  directoriesRemaining: result.progress.directoriesRemaining,
                                  isComplete: result.isComplete)
    }

    private enum LargeFolderChoice { case addAnyway, chooseSubfolder, cancel }

    private static func confirmLargeFolder(_ url: URL,
                                           estimate: FolderSizeEstimate) -> LargeFolderChoice {
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” is a large folder"
        alert.informativeText = """
            It holds at least \(estimate.itemsSeen.formatted()) items, so scanning it may take a while.

            You can keep working while it fills in, and stop it at any time — it picks up where it left off.
            """
        // First button is the default: the warning informs, it does not decide.
        alert.addButton(withTitle: "Add Anyway")
        alert.addButton(withTitle: "Choose a Subfolder…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .addAnyway
        case .alertSecondButtonReturn: return .chooseSubfolder
        default:                       return .cancel
        }
    }

    private static func chooseSubfolder(under url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = "Open"
        panel.message = "Choose the folder inside “\(url.lastPathComponent)” to open."
        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif

    // MARK: - Persistence (security-scoped bookmarks)

    private static let bookmarksKey = "collectionBookmarks"
    /// Cache directories of direct-API collections, so they come back on launch.
    private static let remoteCachesKey = "remoteCollectionCaches"
    /// Last-known paths, index-aligned with `bookmarksKey`. Kept purely so a
    /// collection whose bookmark no longer resolves can still be *named* on
    /// screen — otherwise the only honest thing left to say would be nothing,
    /// which is what it used to say.
    private static let pathsKey = "collectionPaths"
    private static let legacyKey = "vaultBookmark"

    /// Reopen the collections that were open at last quit. Call once at launch.
    func restore() async {
        let store = UserDefaults.standard
        var datas = (store.array(forKey: Self.bookmarksKey) as? [Data]) ?? []
        var paths = (store.array(forKey: Self.pathsKey) as? [String]) ?? []

        // Migrate a single legacy vault bookmark into the new list.
        if datas.isEmpty, let legacy = store.data(forKey: Self.legacyKey) {
            datas = [legacy]
            paths = []
            store.removeObject(forKey: Self.legacyKey)
        }

        // `open(url:)` awaits each collection's off-main scan before returning,
        // so restoring several folders used to cost the *sum* of their cold-scan
        // latencies at every launch. Create them up front (cheap, main-actor)
        // and let the scans overlap: activate() suspends on scanOffMain() and
        // git.refreshStatus(), which frees the main actor for its siblings, so
        // the launch now costs the slowest scan rather than all of them.
        var restored: [Collection] = []
        var refreshedBookmarks = false

        for (index, data) in datas.enumerated() {
            let lastKnownPath = index < paths.count ? paths[index] : nil

            guard let resolved = Bookmark.resolveRefreshing(data) else {
                // The bookmark is dead — the folder is gone, or its volume is.
                // Dropping it here is what made collections silently disappear
                // between launches. Keep it, say why, and let the user decide.
                guard let lastKnownPath else { continue }   // pre-migration: nothing to show
                let url = URL(fileURLWithPath: lastKnownPath)
                let id = url.standardizedFileURL.path
                guard !collections.contains(where: { $0.id == id }) else { continue }
                let collection = Collection(rootURL: url)
                collection.bookmarkData = data
                collection.markUnavailable(Collection.unavailability(of: url) ?? .missing)
                collections.append(collection)
                continue
            }
            if resolved.refreshed != nil { refreshedBookmarks = true }

            let url = resolved.url
            let id = url.standardizedFileURL.path
            guard !collections.contains(where: { $0.id == id }) else { continue }
            let collection = Collection(rootURL: url)
            collection.bookmarkData = resolved.refreshed ?? data
            collections.append(collection)
            restored.append(collection)
        }

        // A re-minted bookmark is only useful once it is written back.
        if refreshedBookmarks { persist() }
        await restoreRemoteCollections()
        guard !restored.isEmpty else { return }

        let externalChange: @MainActor () -> Void = { [weak self] in self?.onExternalChange() }
        await withTaskGroup(of: Void.self) { group in
            for collection in restored {
                group.addTask { @MainActor in
                    await collection.activate(onExternalChange: externalChange)
                }
            }
        }

        // Focus the last restored collection and persist once, matching the
        // serial version's end state.
        focusedID = restored.last?.id ?? focusedID
        for collection in restored { onOpened(collection.rootURL) }
        persist()
    }

    private func persist() {
        // Keep the two arrays index-aligned, and keep an *unavailable*
        // collection's existing bookmark rather than trying to re-mint one from
        // a folder that isn't there — re-minting would fail and quietly drop it,
        // which is the behaviour this whole path exists to end.
        var datas: [Data] = []
        var paths: [String] = []
        for collection in collections {
            guard let data = collection.bookmarkData ?? Bookmark.data(for: collection.rootURL)
            else { continue }
            collection.bookmarkData = data
            datas.append(data)
            paths.append(collection.rootURL.path)
        }
        UserDefaults.standard.set(datas, forKey: Self.bookmarksKey)
        UserDefaults.standard.set(paths, forKey: Self.pathsKey)

        // Direct-API collections live in our own container, so they need no
        // bookmark — just the cache directory, which the manifest inside it
        // describes completely.
        let remotes = collections.compactMap { $0.remote?.cacheRoot.path }
        UserDefaults.standard.set(remotes, forKey: Self.remoteCachesKey)
    }

    /// Rebuild the direct-API collections that were open at last quit.
    ///
    /// Restoring these used to be refused on the grounds that a stale cache
    /// shouldn't masquerade as a collection — which was right while staleness was
    /// undetectable. The manifest changed that: it records a delta cursor, so the
    /// collection comes back **instantly from cache** and then asks the provider
    /// what has changed. The alternative was making the user reconnect every
    /// session to see notes that were already on disk.
    private func restoreRemoteCollections() async {
        let caches = (UserDefaults.standard.array(forKey: Self.remoteCachesKey) as? [String]) ?? []
        for path in caches {
            let cacheRoot = URL(fileURLWithPath: path, isDirectory: true)
            guard let manifest = RemoteManifest.load(fromCacheRoot: cacheRoot) else { continue }
            guard let store = Self.makeStore(named: manifest.provider) else { continue }
            let id = cacheRoot.standardizedFileURL.path
            guard !collections.contains(where: { $0.id == id }) else { continue }

            let mirror = RemoteMirror(store: store, cacheRoot: cacheRoot,
                                      remoteRoot: manifest.remoteRoot,
                                      displayName: manifest.displayName)
            let collection = Collection(rootURL: cacheRoot)
            collection.remote = mirror
            collections.append(collection)
            await collection.activate(onExternalChange: { [weak self] in self?.onExternalChange() })

            // Then reconcile in the background — the cached notes are already on
            // screen, so a slow provider costs nothing but freshness.
            Task { [weak collection] in await collection?.refreshFromProvider() }
        }
    }

    /// Recreate a provider client from the name its manifest recorded.
    private static func makeStore(named provider: String) -> RemoteStore? {
        switch provider {
        case DropboxStore().providerName:     return DropboxStore()
        case BoxStore().providerName:         return BoxStore()
        case GoogleDriveStore().providerName: return GoogleDriveStore()
        case OneDriveStore().providerName:    return OneDriveStore()
        default:                              return nil
        }
    }

    /// Try an unavailable collection again — the drive was plugged back in, or
    /// the folder came out of the Trash. Re-resolves the bookmark first, so a
    /// folder that *moved* is followed rather than reported missing forever.
    @discardableResult
    func retry(_ collection: Collection) async -> Bool {
        if let data = collection.bookmarkData,
           let resolved = Bookmark.resolveRefreshing(data) {
            if let refreshed = resolved.refreshed { collection.bookmarkData = refreshed }
            // Moved: the bookmark tracks the folder by identity, so it now points
            // somewhere else. The collection's id *is* its path, so it has to be
            // reopened there rather than mutated in place.
            if resolved.url.standardizedFileURL.path != collection.id {
                close(collection)
                await open(url: resolved.url)
                return true
            }
        }
        let back = await collection.recheckAvailability()
        if back { persist() }
        return back
    }
}

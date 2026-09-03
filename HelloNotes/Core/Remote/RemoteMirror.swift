//
//  RemoteMirror.swift
//  HelloNotes
//
//  Created by Chris Tham on 21/7/2026.
//
//  Bridges a `RemoteStore` (Dropbox, …) into the app's filesystem-based
//  `Collection` model so a cloud account can be a *first-class collection* in the
//  sidebar. It mirrors the remote folder into a local cache directory; that cache
//  is opened as an ordinary `Collection`, so every existing surface — scan,
//  index, backlinks, the editor, `FileIO` — works unchanged. Edits saved into the
//  cache are uploaded back to the provider (`Collection.noteDidSave` calls
//  `upload`).
//
//  MVP scope: `syncDown()` fetches the folder's Markdown eagerly (notes vaults are
//  small); on-demand hydration of a remote collection is a later refinement.
//

import Foundation

/// Live counts while a remote folder is being mirrored, so the UI can show what
/// is happening instead of an unexplained wait.
struct RemoteSyncProgress: Sendable, Equatable {
    var foldersListed = 0
    var notesDownloaded = 0
    var notesUpToDate = 0
    /// Files passed over because the mirror currently carries Markdown only.
    /// Counted rather than ignored: a folder of PDFs otherwise produces an empty
    /// collection with no hint as to why. (Zero since the mirror became
    /// metadata-first — it now carries every file.)
    var otherFilesSkipped = 0
    /// Files given a name and a place in the tree, whose content is fetched when
    /// something asks for it.
    var filesMirrored = 0
    /// The folder or note currently being fetched, for a status line.
    var currentPath = ""
}

/// One item the sync could not fetch. Recorded and reported rather than thrown,
/// so a single unreadable folder doesn't cost the user everything else.
struct RemoteSyncFailure: Sendable, Equatable {
    var path: String
    var message: String
}

/// What a `syncDown` actually achieved.
///
/// `isComplete` is the important field: it is true **only** when the entire
/// remote tree was listed without cancellation or failure. Anything that
/// deletes local state must consult it — a partial pass has not seen the whole
/// remote folder, so a note "missing" from it may simply live in a subtree the
/// walk never reached.
struct RemoteSyncOutcome: Sendable, Equatable {
    var progress = RemoteSyncProgress()
    var failures: [RemoteSyncFailure] = []
    var isComplete = false
    /// A few names of the skipped non-Markdown files, so the report can be
    /// concrete about what was left behind rather than just counting it.
    var skippedExamples: [String] = []
}

final class RemoteMirror {
    let store: RemoteStore
    /// Local cache directory that stands in for the remote folder.
    let cacheRoot: URL
    /// Provider-absolute path of the mirrored folder ("" = provider root).
    let remoteRoot: String
    /// Shown in the sidebar (the remote folder's name, or the provider name at root).
    let displayName: String

    init(store: RemoteStore, cacheRoot: URL, remoteRoot: String, displayName: String) {
        self.store = store
        self.cacheRoot = cacheRoot
        self.remoteRoot = DropboxPath.normalize(remoteRoot)
        self.displayName = displayName
    }

    // MARK: - Path mapping

    /// The local cache URL for a provider-absolute path.
    func localURL(forRemotePath path: String) -> URL {
        let p = DropboxPath.normalize(path)
        var rel = p
        if !remoteRoot.isEmpty, p.hasPrefix(remoteRoot) {
            rel = String(p.dropFirst(remoteRoot.count))
        }
        rel = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        return cacheRoot.appendingPathComponent(rel)
    }

    /// The provider-absolute path for a local cache URL.
    func remotePath(forLocalURL url: URL) -> String {
        let rel = url.standardizedFileURL.path
            .replacingOccurrences(of: cacheRoot.standardizedFileURL.path, with: "")
        let clean = rel.hasPrefix("/") ? rel : "/" + rel
        return remoteRoot.isEmpty ? clean : remoteRoot + clean
    }

    // MARK: - Sync

    /// Fetch the remote folder's Markdown into the local cache (recursive), then
    /// reconcile: prune local notes that no longer exist remotely.
    ///
    /// Three rules keep this from destroying work:
    /// * a local file **newer** than the remote copy is left alone — it's an
    ///   edit whose upload hasn't landed yet, and overwriting it would silently
    ///   discard the user's changes;
    /// * a local note absent from the remote listing is removed, so a note
    ///   deleted elsewhere doesn't linger (and get resurrected by the next save)
    ///   — but **only after a complete pass** (see `RemoteSyncOutcome`);
    /// * one unreadable folder or note costs its own subtree, not the whole
    ///   sync. Only the *root* listing failing is fatal, because that means we
    ///   have nothing at all — an auth failure or a bad path, which the user
    ///   must see rather than receive as an empty collection.
    ///
    /// Cancellation is honoured between every request and returns what was
    /// fetched so far, marked incomplete.
    @discardableResult
    func syncDown(
        progress report: @escaping @Sendable (RemoteSyncProgress) -> Void = { _ in }
    ) async throws -> RemoteSyncOutcome {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        var outcome = RemoteSyncOutcome()
        var seen = Set<String>()   // standardized local paths present remotely
        var folders = [remoteRoot]
        var isRootListing = true

        while let folder = folders.popLast() {
            if Task.isCancelled { return outcome }

            let entries: [RemoteEntry]
            do {
                entries = try await store.list(path: folder)
            } catch {
                if isRootListing { throw error }
                outcome.failures.append(.init(path: folder, message: Self.describe(error)))
                continue
            }
            isRootListing = false
            outcome.progress.foldersListed += 1
            outcome.progress.currentPath = folder.isEmpty ? "/" : folder
            report(outcome.progress)

            for entry in entries {
                if Task.isCancelled { return outcome }
                let dest = localURL(forRemotePath: entry.path)
                if entry.isDirectory {
                    folders.append(entry.path)
                    seen.insert(dest.standardizedFileURL.path)
                    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    continue
                }
                guard entry.name.lowercased().hasSuffix(".md") else {
                    outcome.progress.otherFilesSkipped += 1
                    if outcome.skippedExamples.count < 3 {
                        outcome.skippedExamples.append(entry.name)
                    }
                    continue
                }
                seen.insert(dest.standardizedFileURL.path)

                // Skip the download when the local copy is strictly newer than
                // the remote one (a pending upload).
                if let remoteModified = entry.modified,
                   let localModified = try? dest.resourceValues(forKeys: [.contentModificationDateKey])
                       .contentModificationDate,
                   localModified > remoteModified {
                    outcome.progress.notesUpToDate += 1
                    continue
                }
                do {
                    let data = try await store.read(path: entry.path)
                    try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                    // Coordinated, like every other read/write of this cache —
                    // the collection opened on it reads through `FileIO`.
                    try FileIO.write(data, to: dest)
                    outcome.progress.notesDownloaded += 1
                    outcome.progress.currentPath = entry.path
                    report(outcome.progress)
                } catch {
                    outcome.failures.append(.init(path: entry.path, message: Self.describe(error)))
                }
            }
        }

        // Only an authoritative pass may delete.
        outcome.isComplete = outcome.failures.isEmpty
        if outcome.isComplete { pruneLocalItems(notIn: seen) }
        return outcome
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Remove cached notes (and now-empty folders) that the remote no longer has.
    private func pruneLocalItems(notIn seen: Set<String>) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: cacheRoot,
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return }
        var directories: [URL] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                directories.append(url)
            } else if url.pathExtension.lowercased() == "md",
                      !seen.contains(url.standardizedFileURL.path) {
                try? fm.removeItem(at: url)
            }
        }
        // Deepest-first so a folder emptied by the pass above can go too.
        for url in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count })
        where !seen.contains(url.standardizedFileURL.path) {
            if let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Upload a locally-saved note back to the provider.
    ///
    /// Before writing, the provider's current revision is compared with the one
    /// recorded when this copy was fetched. If they differ the file changed
    /// elsewhere while we held it, and overwriting would destroy that change —
    /// so **both versions are kept**: the local edit stays where it is, and the
    /// provider's copy is saved beside it as a conflicted copy.
    ///
    /// The provider arbitrates by revision rather than by timestamp on purpose.
    /// Comparing modification dates across devices means trusting two clocks to
    /// agree, which is exactly the weak point of every sync tool that does it.
    func upload(localURL url: URL) async throws {
        let data = try FileIO.readData(at: url)
        let relative = Self.relativePath(of: url, in: cacheRoot)
        let remote = remotePath(forLocalURL: url)
        var current = manifest

        if let known = current.entries[relative]?.rev,
           let live = try? await currentRevision(of: remote),
           live != known {
            try await preserveConflict(remotePath: remote, localURL: url)
            // Adopt the revision we just diverged from, so the next save is a
            // clean write rather than an endless conflict.
            current.entries[relative]?.rev = live
            manifest = current
            throw RemoteMirrorError.conflict(name: url.lastPathComponent)
        }

        try await store.write(data, to: remote)
        current.entries[relative]?.hydrated = true
        current.entries[relative]?.rev = try? await currentRevision(of: remote)
        current.entries[relative]?.size = data.count
        manifest = current
    }

    /// The provider's revision for `remotePath`, or nil if it can't be read.
    private func currentRevision(of remotePath: String) async throws -> String? {
        let parent = RemoteBrowserModel.parent(of: remotePath)
        let entries = try await store.list(path: parent)
        return entries.first { DropboxPath.normalize($0.path) == DropboxPath.normalize(remotePath) }?.rev
    }

    /// Save the provider's version alongside the local one, so neither is lost.
    private func preserveConflict(remotePath: String, localURL url: URL) async throws {
        let theirs = try await store.read(path: remotePath)
        let stamp = Self.conflictStamp.string(from: Date())
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(base) (conflicted copy \(stamp))")
        if !ext.isEmpty { destination.appendPathExtension(ext) }
        try FileIO.write(theirs, to: destination)
    }

    private static let conflictStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Metadata-first mirroring

    /// The cache's record of the remote folder. Loaded lazily; empty until the
    /// first metadata sync.
    private var loadedManifest: RemoteManifest?

    var manifest: RemoteManifest {
        get {
            if let loadedManifest { return loadedManifest }
            let loaded = RemoteManifest.load(fromCacheRoot: cacheRoot)
                ?? RemoteManifest(provider: store.providerName,
                                  accountID: store.accountID,
                                  remoteRoot: remoteRoot,
                                  displayName: displayName)
            loadedManifest = loaded
            return loaded
        }
        set {
            loadedManifest = newValue
            newValue.save(toCacheRoot: cacheRoot)
        }
    }

    /// Mirror the remote folder's **shape** — folders and placeholder files —
    /// without downloading a single byte of content.
    ///
    /// This is what makes a cloud root usable at all. `syncDown` fetched every
    /// note eagerly, which is fine for a notes vault and hopeless for an account
    /// of any size; and it skipped non-Markdown files entirely, so a folder of
    /// PDFs mirrored to an empty collection. Here every file gets a real name at
    /// a real path immediately, and its content arrives when something actually
    /// needs it.
    ///
    /// Runs on the shared `ResumableTreeWalk`, so it is incremental,
    /// cancellable, resumable and per-directory fault-isolated for free.
    @discardableResult
    func syncMetadata(
        progress report: @escaping @Sendable (RemoteSyncProgress) -> Void = { _ in }
    ) async throws -> RemoteSyncOutcome {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        var updated = manifest
        var seen = Set<String>()
        var outcome = RemoteSyncOutcome()
        // One recursive listing for the whole tree where the provider has one,
        // consulted by every `children(of:)` below. The walk is unchanged — it
        // simply stops paying a round trip per folder. See
        // `RecursiveListingCache`.
        let source = RemoteTreeSource(
            store: store, remoteRoot: remoteRoot, cacheRoot: cacheRoot,
            prefetch: RecursiveListingCache(store: store, root: remoteRoot))

        // Counted once and then kept, rather than recounted per directory.
        // `entries.values.count(where:)` walked the *whole* manifest on every
        // batch, so a folder with D directories and E entries did D×E work for a
        // number that changes by one at a time — quadratic in the size of the
        // thing being synced, on the sync's own hot path.
        var fileCount = updated.entries.values.count { !$0.isDirectory }

        let result = await ResumableTreeWalk.run(source: source) { batch in
            for child in batch.children {
                let relative = Self.relativePath(of: child.url, in: cacheRoot)
                seen.insert(relative)
                let existing = updated.entries[relative]
                let wasFile = existing.map { !$0.isDirectory } ?? false

                if child.isDirectory {
                    try? fm.createDirectory(at: child.url, withIntermediateDirectories: true)
                    updated.entries[relative] = RemoteManifest.Entry(
                        remotePath: source.remotePath(for: child.url),
                        isDirectory: true)
                    if wasFile { fileCount -= 1 }
                    continue
                }
                // Keep an existing hydration flag: a note already downloaded
                // stays downloaded unless the provider says it changed.
                let unchanged = existing?.rev != nil && existing?.rev == child.rev
                let entry = RemoteManifest.Entry(
                    remotePath: source.remotePath(for: child.url),
                    isDirectory: false,
                    size: child.size,
                    modified: child.modified,
                    rev: child.rev,
                    hydrated: (existing?.hydrated ?? false) && unchanged)
                updated.entries[relative] = entry
                if !wasFile { fileCount += 1 }
                if !entry.hydrated { Self.writePlaceholder(at: child.url) }
            }
            outcome.progress.foldersListed = batch.progress.directoriesVisited
            outcome.progress.filesMirrored = fileCount
            outcome.progress.currentPath = batch.directory
            report(outcome.progress)
        }

        outcome.failures = result.issues.map { RemoteSyncFailure(path: $0.path, message: $0.message) }
        outcome.isComplete = result.isComplete

        // Only an authoritative pass may delete — the same rule that protects a
        // cancelled local walk, and the one a delta must also respect.
        if result.isComplete {
            for key in updated.entries.keys where !seen.contains(key) {
                updated.entries.removeValue(forKey: key)
            }
            pruneLocalItems(notIn: Set(seen.map { cacheRoot.appending(path: $0).standardizedFileURL.path }))
        }
        // Take a cursor while we are here. A full sync has just seen the whole
        // folder, so "everything up to now" is exactly what it describes — and
        // acquiring it costs one metadata request instead of making the first
        // refresh re-list the folder purely to find its place.
        if result.isComplete, updated.deltaCursor == nil {
            updated.deltaCursor = try? await store.latestCursor(path: remoteRoot)
        }
        updated.lastRefresh = Date()
        manifest = updated
        return outcome
    }

    /// Bring the cache up to date with the provider.
    ///
    /// Uses the provider's own delta feed when it has one — one request for
    /// "everything since this cursor" instead of re-walking a tree that may be
    /// thousands of listings — and falls back to a full metadata sync otherwise,
    /// or when the provider says the cursor has expired.
    ///
    /// **A delta may never prune.** It reports what changed, not what exists, so
    /// an item absent from it is simply an item that did not change. Deletions
    /// come from the feed's own explicit list; anything else is only removed by
    /// a complete `syncMetadata`.
    @discardableResult
    func refresh() async throws -> RemoteSyncOutcome {
        var current = manifest
        guard let delta = try await store.changes(since: current.deltaCursor,
                                                  path: remoteRoot) else {
            return try await syncMetadata()
        }
        if delta.requiresFullResync {
            current.deltaCursor = nil
            manifest = current
            return try await syncMetadata()
        }

        let source = RemoteTreeSource(store: store, remoteRoot: remoteRoot, cacheRoot: cacheRoot)
        var outcome = RemoteSyncOutcome()

        for entry in delta.changed {
            let url = source.cacheURL(forRemotePath: entry.path)
            let relative = Self.relativePath(of: url, in: cacheRoot)
            guard !relative.isEmpty else { continue }
            if entry.isDirectory {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                current.entries[relative] = RemoteManifest.Entry(remotePath: entry.path, isDirectory: true)
                continue
            }
            let existing = current.entries[relative]
            let unchanged = existing?.rev != nil && existing?.rev == entry.rev
            current.entries[relative] = RemoteManifest.Entry(
                remotePath: entry.path,
                isDirectory: false,
                size: entry.size,
                modified: entry.modified,
                rev: entry.rev,
                hydrated: (existing?.hydrated ?? false) && unchanged)
            if !unchanged { Self.writePlaceholder(at: url) }
        }

        for path in delta.deleted {
            let url = source.cacheURL(forRemotePath: path)
            let relative = Self.relativePath(of: url, in: cacheRoot)
            guard !relative.isEmpty else { continue }
            current.entries.removeValue(forKey: relative)
            try? FileManager.default.removeItem(at: url)
        }

        current.deltaCursor = delta.cursor
        current.lastRefresh = Date()
        manifest = current

        outcome.isComplete = true
        outcome.progress.filesMirrored = current.entries.values.count { !$0.isDirectory }
        return outcome
    }

    /// Fetch one file's real content and mark it hydrated.
    ///
    /// Idempotent, so the editor can call it unconditionally on open.
    func hydrate(localURL url: URL) async throws {
        let relative = Self.relativePath(of: url, in: cacheRoot)
        var current = manifest
        guard let entry = current.entries[relative], !entry.isDirectory else { return }
        guard !entry.hydrated else { return }

        let data = try await store.read(path: entry.remotePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try FileIO.write(data, to: url)
        current.entries[relative]?.hydrated = true
        manifest = current
    }

    func isHydrated(localURL url: URL) -> Bool {
        manifest.isHydrated(Self.relativePath(of: url, in: cacheRoot))
    }

    /// Cache-relative paths whose content has not been fetched, for the scan.
    var dehydratedRelativePaths: Set<String> { manifest.dehydratedPaths }

    /// A zero-byte stand-in, so the file exists at its real path with its real
    /// name. **Never** written over a file that already has content: the whole
    /// hydration gate exists to keep a placeholder from being mistaken for an
    /// empty note.
    /// One stat instead of three.
    ///
    /// This runs once per file in the folder, so its cost is multiplied by the
    /// thing that makes a large folder large. It used to ask the file system
    /// three separate questions — a `resourceValues` for the size, a
    /// `createDirectory` for a parent the walk had already created moments
    /// earlier, and a `fileExists` for what the first call had already
    /// established. In the common case — a re-sync, where every file is already
    /// there — that is three syscalls per note to decide to do nothing.
    private static func writePlaceholder(at url: URL) {
        let fm = FileManager.default
        // Present either way — non-empty means hydrated, empty means the
        // placeholder is already there — and neither needs writing.
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data())
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        var relative = String(full.dropFirst(base.count))
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    // MARK: - Bounding the cache

    /// How much downloaded content a mirror may hold before the least recently
    /// used bodies are dropped back to placeholders.
    ///
    /// A lazy cache that never lets go is only a slower version of downloading
    /// everything: open enough of a large account and you have mirrored it in
    /// full. Evicting costs nothing but a re-download on next open, which is the
    /// same cost the file had before it was ever opened.
    static let defaultCacheLimit = 256 * 1024 * 1024      // 256 MB

    /// Total bytes of hydrated content.
    var hydratedBytes: Int {
        manifest.entries.values.reduce(0) { $0 + ($1.hydrated && !$1.isDirectory ? $1.size : 0) }
    }

    /// Drop least-recently-opened content until the cache fits `limit`.
    ///
    /// "Least recently used" is the filesystem's own access time, so a note read
    /// five minutes ago outranks one opened a month ago without the mirror having
    /// to keep its own log. `keeping` is never evicted — it is what the user is
    /// looking at.
    @discardableResult
    func evictIfNeeded(limit: Int = RemoteMirror.defaultCacheLimit,
                       keeping pinned: Set<String> = []) -> Int {
        var current = manifest
        var total = hydratedBytes
        guard total > limit else { return 0 }

        let candidates = current.entries
            .filter { !$0.value.isDirectory && $0.value.hydrated && !pinned.contains($0.key) }
            .map { (path: $0.key, entry: $0.value, used: Self.lastUsed(cacheRoot.appending(path: $0.key))) }
            .sorted { $0.used < $1.used }          // oldest first

        var evicted = 0
        for candidate in candidates where total > limit {
            let url = cacheRoot.appending(path: candidate.path)
            // Back to a placeholder rather than gone: the name must stay, or the
            // note would vanish from the collection entirely.
            guard (try? Data().write(to: url, options: .atomic)) != nil else { continue }
            current.entries[candidate.path]?.hydrated = false
            total -= candidate.entry.size
            evicted += 1
        }
        if evicted > 0 { manifest = current }
        return evicted
    }

    private static func lastUsed(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        return values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
    }

    // MARK: - Cache location

    /// A stable per-provider/per-folder cache directory in Application Support
    /// (not Caches — the system may purge Caches, and this is the working copy).
    static func cacheDirectory(provider: String, folder: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let safeFolder = folder.isEmpty ? "root" : folder
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return base
            .appendingPathComponent("RemoteMirror", isDirectory: true)
            .appendingPathComponent(provider.lowercased(), isDirectory: true)
            .appendingPathComponent(safeFolder.isEmpty ? "root" : safeFolder, isDirectory: true)
    }
}

enum RemoteMirrorError: LocalizedError {
    case conflict(name: String)
    var errorDescription: String? {
        switch self {
        case .conflict(let name):
            return "“\(name)” also changed on the provider. Your version is kept here, "
                 + "and theirs was saved beside it as a conflicted copy."
        }
    }
}

/// Small Dropbox-style path helpers (shared with DropboxStore's conventions).
enum DropboxPath {
    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "/" || p.isEmpty { return "" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

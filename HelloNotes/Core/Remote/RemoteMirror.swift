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
    /// collection with no hint as to why.
    var otherFilesSkipped = 0
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

    /// Upload a locally-saved note back to the provider. Best-effort — a failure
    /// is surfaced by the caller; the local cache still holds the edit.
    func upload(localURL url: URL) async throws {
        let data = try FileIO.readData(at: url)
        try await store.write(data, to: remotePath(forLocalURL: url))
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

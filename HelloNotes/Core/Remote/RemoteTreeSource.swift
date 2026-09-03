//
//  RemoteTreeSource.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/8/2026.
//
//  A provider's folder tree, listed one directory at a time.
//
//  The whole point of `TreeSource` being one method: this is the only thing that
//  differs between walking a folder on disk and walking a Dropbox account. The
//  frontier, checkpointing, progress, cancellation, resumption and per-directory
//  fault isolation are the same code either way — which matters most here, where
//  a directory listing is a network round trip and interruptions are the norm.
//

import Foundation

struct RemoteTreeSource: TreeSource {
    let store: RemoteStore
    /// Provider-absolute path of the mirrored folder ("" = provider root).
    let remoteRoot: String
    /// Where the mirror lives locally; children are reported as cache URLs so
    /// the walk's output slots straight into the collection's model.
    let cacheRoot: URL

    /// Nothing to check up front: reachability is whatever the first request
    /// says, and an auth failure surfaces as a thrown listing rather than a
    /// guess made in advance.
    func unavailability() -> CollectionState.UnavailableReason? { nil }

    /// Six listings in flight.
    ///
    /// Every `store.list` is a network round trip the app spends idle, so a
    /// folder of N directories used to cost N latencies end to end — which is
    /// the entire reason adding a large cloud folder felt slow. Six is chosen to
    /// be well inside every provider's rate limit rather than to saturate a
    /// link: Dropbox, Box, Graph and Drive all throttle, and a walk that earns a
    /// 429 finishes later than one that never asked for it.
    var listingConcurrency: Int { 6 }

    /// Answers every listing from one recursive fetch, when the provider can do
    /// one. Shared by reference so the `struct` stays a value the walk can copy.
    var prefetch: RecursiveListingCache? = nil

    func children(of directory: String) async throws -> DirectoryListing {
        // **One request for the tree, rather than one per folder.**
        //
        // The walk stays exactly as it is — frontier, checkpoints, progress,
        // per-directory fault isolation, resumption — and simply stops paying a
        // network latency for each step. Overlapping six listings still leaves
        // N/6 round trips for N folders; this leaves a handful for the whole
        // tree. A provider without the call returns nil and nothing changes.
        if let prefetch, let cached = await prefetch.children(of: remotePath(forRelative: directory)) {
            return listing(from: cached)
        }
        let entries = try await store.list(path: remotePath(forRelative: directory))
        return listing(from: entries)
    }

    /// One directory's entries, as the walk's own shape.
    private func listing(from entries: [RemoteEntry]) -> DirectoryListing {
        var listing = DirectoryListing()
        listing.children.reserveCapacity(entries.count)
        for entry in entries {
            let url = cacheURL(forRemotePath: entry.path)
            listing.children.append(TreeChild(
                url: url,
                isDirectory: entry.isDirectory,
                isPackage: false,
                isMarkdown: entry.name.lowercased().hasSuffix(".md"),
                modified: entry.modified ?? .distantPast,
                size: entry.size,
                // Every file starts life here as a name without content. The
                // mirror flips this once the bytes are fetched.
                isOnlineOnly: !entry.isDirectory,
                rev: entry.rev))
        }
        return listing
    }

    // MARK: Path mapping

    func remotePath(forRelative relative: String) -> String {
        guard !relative.isEmpty else { return remoteRoot }
        return remoteRoot.isEmpty ? "/" + relative : remoteRoot + "/" + relative
    }

    func cacheURL(forRemotePath path: String) -> URL {
        let normalized = DropboxPath.normalize(path)
        var relative = normalized
        if !remoteRoot.isEmpty, normalized.hasPrefix(remoteRoot) {
            relative = String(normalized.dropFirst(remoteRoot.count))
        }
        while relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? cacheRoot : cacheRoot.appending(path: relative)
    }

    func remotePath(for cacheURL: URL) -> String {
        let relative = RemoteMirror.relativePath(of: cacheURL, in: cacheRoot)
        return remotePath(forRelative: relative)
    }
}

/// One recursive listing, fetched once and then answered from memory.
///
/// **Why a cache rather than replacing the walk.** The obvious use of a
/// recursive listing is to build the tree from it directly and skip
/// `ResumableTreeWalk` entirely — and that would throw away the checkpointing,
/// the incremental publishing, the per-directory fault isolation and the
/// resumption that make a large, interrupted sync survivable. All of that is
/// worth more than the walk's own bookkeeping costs. So the walk is left intact
/// and only its *expensive* step is made free.
///
/// Failure is not fatal by design: a provider that has no recursive call, or one
/// whose call fails, leaves `entries` nil and every listing falls through to
/// `store.list` exactly as before. The attempt is made once — a provider that
/// refused will refuse again, and retrying per directory would be slower than
/// never having tried.
actor RecursiveListingCache {
    private let store: RemoteStore
    private let root: String
    private var byDirectory: [String: [RemoteEntry]]?
    private var attempted = false

    init(store: RemoteStore, root: String) {
        self.store = store
        self.root = root
    }

    /// The entries directly inside `path`, or nil when there is no prefetch to
    /// answer from.
    func children(of path: String) async -> [RemoteEntry]? {
        if !attempted {
            attempted = true
            byDirectory = await fetch()
        }
        return byDirectory?[normalise(path)] ?? (byDirectory == nil ? nil : [])
    }

    private func fetch() async -> [String: [RemoteEntry]]? {
        // `try?` flattens the double optional, so "threw" and "not supported"
        // arrive the same way — which is what we want: both mean walk instead.
        guard let entries = try? await store.listRecursively(path: root) else { return nil }
        // Group by parent. A recursive listing arrives flat and in no
        // particular order, and the walk asks for one directory at a time.
        var grouped: [String: [RemoteEntry]] = [:]
        for entry in entries {
            let parent = normalise((entry.path as NSString).deletingLastPathComponent)
            grouped[parent, default: []].append(entry)
        }
        return grouped
    }

    /// Providers disagree about the trailing slash and about the case of the
    /// root; the walk asks with whatever `remotePath(forRelative:)` produced.
    private func normalise(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p.lowercased()
    }
}

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

    func children(of directory: String) async throws -> DirectoryListing {
        let entries = try await store.list(path: remotePath(forRelative: directory))
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

//
//  RemoteManifest.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/8/2026.
//
//  What the local cache of a remote folder knows about that folder.
//
//  The mirror used to hold no state beyond the files themselves, which forced
//  every question to be answered by asking the provider again — and left no way
//  to express the one thing a lazy cache must express: that a file is *here as a
//  name* but not *here as content*. The manifest is that record, plus the
//  cache's resume point and its staleness cursor.
//

import Foundation

/// The cache's index, staleness record and resume point, in one file.
///
/// `nonisolated`: a value, encoded and written away from the main actor
/// (`ManifestWriter`).
nonisolated struct RemoteManifest: Codable, Sendable {

    struct Entry: Codable, Sendable, Equatable {
        /// Provider-absolute path.
        var remotePath: String
        var isDirectory: Bool = false
        var size: Int = 0
        var modified: Date?
        /// The provider's own revision id. Carried since the first version of
        /// `RemoteEntry` and finally used here: it is what lets an upload be
        /// conditional, so the provider itself arbitrates a conflict and no
        /// clock has to be trusted.
        var rev: String?
        /// Whether the local file holds the real bytes, or is a placeholder
        /// standing in for them.
        var hydrated: Bool = false
        /// The local file holds a change the provider has not received — a
        /// save waiting its turn, one whose upload failed, mine kept here
        /// after a conflict. Nothing may replace it: not trimming the cache,
        /// not a walk that sees the provider's copy change (the upload's own
        /// conflict check keeps both), not a download. Optional, so a record
        /// written before it decodes — as not unsent.
        var unsent: Bool?
    }

    var provider: String
    /// Which connected account this collection came from. `nil` only in a
    /// manifest written before accounts existed, which cannot be restored
    /// because there is no way to know whose credentials it needs.
    var accountID: String?
    var remoteRoot: String
    var displayName: String
    /// The provider's delta cursor, when it has one.
    var deltaCursor: String?
    var lastRefresh: Date?
    /// When a walk last listed the whole folder. Until one has, a file here the
    /// manifest has no record of may be one the provider has and the walk has
    /// not reached — so nothing is sent up as made here before it.
    ///
    /// Optional, like every field added after the first release: a manifest
    /// written without it still decodes, where a new non-optional field would
    /// make `load` fail and the cache forget every download.
    var lastCompleteSync: Date?
    /// Keyed by cache-relative path (`"Notes/Idea.md"`).
    var entries: [String: Entry] = [:]

    // MARK: Queries

    /// Cache-relative paths whose content has not been fetched. Handed to the
    /// scan so those notes present as online-only, which lights up every piece
    /// of cloud UX the app already has.
    var dehydratedPaths: Set<String> {
        Set(entries.lazy.filter { !$0.value.isDirectory && !$0.value.hydrated }.map(\.key))
    }

    /// True sizes, so a placeholder does not report itself as 0 bytes.
    var sizes: [String: Int] {
        entries.reduce(into: [:]) { result, pair in
            if !pair.value.isDirectory { result[pair.key] = pair.value.size }
        }
    }

    func isHydrated(_ relativePath: String) -> Bool {
        entries[relativePath]?.hydrated ?? false
    }

    // MARK: Storage

    /// Hidden, so the collection's own scan skips it (`.skipsHiddenFiles`) and
    /// the manifest never shows up as an attachment inside the collection it
    /// describes.
    static let filename = ".hellonotes-mirror.json"

    static func url(inCacheRoot root: URL) -> URL {
        root.appendingPathComponent(filename)
    }

    /// The manifest on disk — after any write still on its way there.
    static func load(fromCacheRoot root: URL) -> RemoteManifest? {
        ManifestWriter.for(root).flush()
        guard let data = try? Data(contentsOf: url(inCacheRoot: root)) else { return nil }
        return try? JSONDecoder().decode(RemoteManifest.self, from: data)
    }

    func save(toCacheRoot root: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: Self.url(inCacheRoot: root), options: .atomic)
    }
}

/// Writes one cache's manifest, away from the main actor.
///
/// Every change a cloud collection makes — an upload, a move, a new folder, a
/// delete — records itself in the manifest, and the whole manifest was encoded
/// and written on the main actor each time: 22 ms at 10,000 entries, 127 ms at
/// 50,000, measured by the concurrency review of implemented.md §51.21. Here
/// each record replaces any not yet written, so a burst of changes costs one
/// write, on a queue of the cache's own; a load waits for what is still on its
/// way (`RemoteManifest.load`).
nonisolated final class ManifestWriter: @unchecked Sendable {
    private let root: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var waiting: RemoteManifest?

    private init(root: URL) {
        self.root = root
        queue = DispatchQueue(label: "com.hellotham.HelloNotes.manifest", qos: .utility)
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var writers: [String: ManifestWriter] = [:]

    /// The writer for the cache at `root` — one per cache, so two writes of
    /// one manifest are never in flight at once.
    static func `for`(_ root: URL) -> ManifestWriter {
        let key = root.standardizedFileURL.path
        registryLock.lock(); defer { registryLock.unlock() }
        if let writer = writers[key] { return writer }
        let writer = ManifestWriter(root: root)
        writers[key] = writer
        return writer
    }

    /// Write `manifest`, replacing any not yet written.
    func save(_ manifest: RemoteManifest) {
        lock.lock()
        let scheduled = waiting != nil
        waiting = manifest
        lock.unlock()
        guard !scheduled else { return }        // the write already scheduled takes this one
        queue.async { [self] in
            lock.lock()
            let next = waiting
            waiting = nil
            lock.unlock()
            next?.save(toCacheRoot: root)
        }
    }

    /// Wait until every manifest handed over so far is written.
    func flush() {
        queue.sync {}
    }
}

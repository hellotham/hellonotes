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
struct RemoteManifest: Codable, Sendable {

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
    }

    var provider: String
    var remoteRoot: String
    var displayName: String
    /// The provider's delta cursor, when it has one.
    var deltaCursor: String?
    var lastRefresh: Date?
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

    static func load(fromCacheRoot root: URL) -> RemoteManifest? {
        guard let data = try? Data(contentsOf: url(inCacheRoot: root)) else { return nil }
        return try? JSONDecoder().decode(RemoteManifest.self, from: data)
    }

    func save(toCacheRoot root: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: Self.url(inCacheRoot: root), options: .atomic)
    }
}

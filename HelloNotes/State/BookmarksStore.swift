//
//  BookmarksStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Observation

/// Per-collection bookmarks: notes the user has pinned for quick access. Stored
/// as a list of collection-relative paths in `UserDefaults`, keyed by the
/// collection's path, so each collection keeps its own set.
@MainActor
@Observable
final class BookmarksStore {
    /// Bookmarked notes as collection-relative paths, in the order added.
    private(set) var paths: [String] = []

    private var rootURL: URL?
    /// The root's spellings, and the key its bookmarks are stored under —
    /// worked out with the collection's identity, off the main actor where it
    /// is opened (`Collection.Identity`). Each was asked of the root's
    /// `standardizedFileURL` at every `isBookmarked` — a sidebar row's — which
    /// on an iPhone's `/private/var/…` root is a look at the disk
    /// (implemented.md §51.67).
    private var rootSpellings: [String] = []
    private var storageKey: String?

    /// Point the store at a collection and load its saved bookmarks.
    /// `standardizedPath` and `spellings` are the root's, from its identity;
    /// without them they are worked out here.
    func load(rootURL: URL?, standardizedPath: String? = nil, spellings: [String]? = nil) {
        self.rootURL = rootURL
        storageKey = (standardizedPath ?? rootURL?.standardizedFileURL.path).map { "bookmarks:" + $0 }
        rootSpellings = spellings ?? rootURL.map(CollectionIndexCache.rootPrefixes) ?? []
        guard let storageKey else { paths = []; return }
        paths = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    func isBookmarked(_ note: Note) -> Bool {
        guard let rel = relativePath(of: note) else { return false }
        return paths.contains(rel)
    }

    /// Add or remove `note` from bookmarks and persist.
    func toggle(_ note: Note) {
        guard let rel = relativePath(of: note) else { return }
        if let index = paths.firstIndex(of: rel) {
            paths.remove(at: index)
        } else {
            paths.append(rel)
        }
        persist()
    }

    /// The bookmarked notes present in `notes`, in bookmark order. (Bookmarks to
    /// notes that no longer exist are simply skipped.)
    func bookmarkedNotes(from notes: [Note]) -> [Note] {
        let byRel = Dictionary(
            notes.compactMap { note in relativePath(of: note).map { ($0, note) } },
            uniquingKeysWith: { first, _ in first }
        )
        return paths.compactMap { byRel[$0] }
    }

    /// Keep a pin after the note is renamed or moved: rewrite its stored relative
    /// path so the bookmark doesn't silently dangle (bookmarks key on path).
    func updatePath(from oldURL: URL, to newURL: URL) {
        guard let oldRel = relativePath(ofURL: oldURL),
              let newRel = relativePath(ofURL: newURL),
              let index = paths.firstIndex(of: oldRel) else { return }
        paths[index] = newRel
        persist()
    }

    // MARK: - Private

    private func relativePath(of note: Note) -> String? {
        relativePath(ofURL: note.fileURL)
    }

    /// Where `url` is inside the collection, under whichever of the root's
    /// names it is spelled — nothing asked of the disk.
    private func relativePath(ofURL url: URL) -> String? {
        let file = url.path
        for spelling in rootSpellings where file.hasPrefix(spelling) {
            return String(file.dropFirst(spelling.count))
        }
        return nil
    }

    private func persist() {
        guard let storageKey else { return }
        UserDefaults.standard.set(paths, forKey: storageKey)
    }
}

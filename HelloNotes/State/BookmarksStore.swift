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

    /// Point the store at a collection and load its saved bookmarks.
    func load(rootURL: URL?) {
        self.rootURL = rootURL
        guard let key = Self.key(for: rootURL) else { paths = []; return }
        paths = UserDefaults.standard.stringArray(forKey: key) ?? []
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

    private func relativePath(ofURL url: URL) -> String? {
        guard let rootURL else { return nil }
        let file = url.standardizedFileURL.path
        var base = rootURL.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        guard file.hasPrefix(base) else { return nil }
        return String(file.dropFirst(base.count))
    }

    private func persist() {
        guard let key = Self.key(for: rootURL) else { return }
        UserDefaults.standard.set(paths, forKey: key)
    }

    private static func key(for rootURL: URL?) -> String? {
        rootURL.map { "bookmarks:" + $0.standardizedFileURL.path }
    }
}

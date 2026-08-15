//
//  RecentsStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Remembers recently-opened collections (most recent first) so the launcher can
//  reopen them with one click. Obsidian vaults are flagged so they can be listed
//  separately. Backed by security-scoped bookmarks in UserDefaults.
//

import Foundation

@MainActor
@Observable
final class RecentsStore {
    struct Entry: Identifiable, Codable {
        var id: String            // standardized path
        var name: String
        var isObsidian: Bool
        var lastOpened: Date
        var bookmark: Data

        var url: URL? { Bookmark.resolve(bookmark)?.url }
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 24
    private static let key = "recentCollections"

    init() { load() }

    /// Obsidian vaults among the recents (for the launcher's dedicated list).
    var obsidianVaults: [Entry] { entries.filter(\.isObsidian) }

    /// Non-Obsidian recent collections.
    var recentCollections: [Entry] { entries.filter { !$0.isObsidian } }

    /// Record that `url` was just opened. Moves it to the front (de-duplicated),
    /// refreshing its bookmark while the security scope is active.
    func record(_ url: URL) {
        let id = url.standardizedFileURL.path
        guard let bookmark = Bookmark.data(for: url) else { return }
        let entry = Entry(
            id: id,
            name: url.lastPathComponent,
            isObsidian: ObsidianVault.isVault(url),
            lastOpened: Date(),
            bookmark: bookmark
        )
        entries.removeAll { $0.id == id }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        persist()
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

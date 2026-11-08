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
//  One entry a collection, wherever the app's container was when it was
//  opened. Entries were told apart by path, and an iOS app's container moves
//  — at every install on the simulator, measured — so each move left the
//  collection listed once more: twenty entries of the sample collection on
//  the simulator, one an install, each opening the same folder
//  (implemented.md §51.71). A collection is now recognised under the
//  container's earlier names as it is recorded (`ContainerPath.placeName`),
//  and what earlier moves left is tidied once a launch (`tidy`).
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
    static let key = "recentCollections"

    /// The app's own preferences, or a test's (`ScratchDefaults`): a hosted
    /// test's store must not write the person's list.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let home: String

    init(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        self.defaults = defaults
        self.home = home
        load()
    }

    /// Obsidian vaults among the recents (for the launcher's dedicated list).
    var obsidianVaults: [Entry] { entries.filter(\.isObsidian) }

    /// Non-Obsidian recent collections.
    var recentCollections: [Entry] { entries.filter { !$0.isObsidian } }

    /// Record that `url` was just opened. Moves it to the front (de-duplicated
    /// by place — the entry kept for it under an earlier name of the app's
    /// container is this one), refreshing its bookmark while the security
    /// scope is active.
    func record(_ url: URL) async {
        // What it asks the disk — the folder's name, a bookmark of it, and
        // whether it is an Obsidian vault — asked on the folder's lane: on the
        // main actor it was asked at every open, and for each collection the
        // launch brought back, of folders a provider can hold (§51.72).
        let (id, bookmark, isObsidian) = await FileIO.onLane(for: url) {
            (url.standardizedFileURL.path, Bookmark.data(for: url), ObsidianVault.isVault(url))
        }
        guard let bookmark else { return }
        // From the list as kept: each window has a store of its own, and one
        // writing its own copy wrote over what another had just recorded.
        load()
        let entry = Entry(
            id: id,
            name: url.lastPathComponent,
            isObsidian: isObsidian,
            lastOpened: Date(),
            bookmark: bookmark
        )
        let earlier = ContainerMoves.earlierHomes(in: defaults)
        let place = ContainerPath.placeName(of: id, home: home, earlierHomes: earlier)
        entries.removeAll { ContainerPath.placeName(of: $0.id, home: home, earlierHomes: earlier) == place }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        persist()
    }

    func remove(_ entry: Entry) {
        // From the list as kept, as `record` does — and by place, so what an
        // earlier container left for the folder goes with it (§51.72).
        load()
        let earlier = ContainerMoves.earlierHomes(in: defaults)
        let place = ContainerPath.placeName(of: entry.id, home: home, earlierHomes: earlier)
        entries.removeAll { ContainerPath.placeName(of: $0.id, home: home, earlierHomes: earlier) == place }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    /// Make one entry of the several that earlier moves of the container left
    /// for one folder — the most recent, named where the folder is now. Only
    /// entries sharing a name can be one folder, so only theirs are looked
    /// at: each bookmark resolved off the main actor, on the scans' lanes,
    /// without mounting anything, since a bookmark follows its folder where a
    /// path does not. One that does not resolve is left as it is. Once a
    /// launch, after the library is back.
    func tidy() async {
        load()
        let byName = Dictionary(grouping: entries, by: \.name)
        let asked = byName.values.filter { $0.count > 1 }.flatMap { $0 }
            .map { (id: $0.id, bookmark: $0.bookmark) }
        guard !asked.isEmpty else { return }
        let found = await offMainAwaiting { () -> [String?] in
            var found: [String?] = []
            for item in asked {
                found.append(await FileIO.onScanLane(for: URL(filePath: item.id, directoryHint: .isDirectory)) {
                    Bookmark.resolve(item.bookmark, mounting: false)?.url.path
                })
            }
            return found
        }
        var now: [String: String] = [:]
        for (item, path) in zip(asked, found) { if let path { now[item.id] = path } }
        // Applied to the list as kept now — another window may have recorded
        // while the bookmarks were resolved, and its records stand (§51.72).
        load()
        let tidied = Self.oneEntryAPlace(entries, now: now, home: home,
                                         earlierHomes: ContainerMoves.earlierHomes(in: defaults))
        guard tidied.map(\.id) != entries.map(\.id) else { return }
        entries = tidied
        persist()
    }

    /// `entries`, the most recent of each place kept and the rest dropped; an
    /// entry whose folder was found (`now`, by id) named where it is.
    static func oneEntryAPlace(_ entries: [Entry], now: [String: String], home: String,
                               earlierHomes: [String]) -> [Entry] {
        var places = Set<String>()
        var kept: [Entry] = []
        for var entry in entries {
            let path = now[entry.id] ?? entry.id
            guard places.insert(ContainerPath.placeName(of: path, home: home, earlierHomes: earlierHomes)).inserted
            else { continue }
            entry.id = path
            kept.append(entry)
        }
        return kept
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard !CaptureSession.isActive else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

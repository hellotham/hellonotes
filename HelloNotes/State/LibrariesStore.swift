//
//  LibrariesStore.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//
//  Saved libraries — named sets of collections the user can reopen together.
//  Each library stores a security-scoped bookmark per collection. Persisted in
//  UserDefaults.
//

import Foundation

@MainActor
@Observable
final class LibrariesStore {
    struct SavedLibrary: Identifiable, Codable {
        var id: UUID = UUID()
        var name: String
        var collectionNames: [String]   // for display without resolving bookmarks
        var bookmarks: [Data]
    }

    private(set) var libraries: [SavedLibrary] = []
    private static let key = "savedLibraries"

    init() { load() }

    /// Save `urls` as a named library (replacing one with the same name).
    func save(name: String, urls: [URL]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !urls.isEmpty else { return }
        let library = SavedLibrary(
            name: trimmed,
            collectionNames: urls.map(\.lastPathComponent),
            bookmarks: urls.compactMap { Bookmark.data(for: $0) }
        )
        libraries.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        libraries.insert(library, at: 0)
        persist()
    }

    func delete(_ library: SavedLibrary) {
        libraries.removeAll { $0.id == library.id }
        persist()
    }

    /// The collection URLs stored in `library` (skipping any that no longer resolve).
    func urls(for library: SavedLibrary) -> [URL] {
        library.bookmarks.compactMap { Bookmark.resolve($0)?.url }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([SavedLibrary].self, from: data) else { return }
        libraries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(libraries) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

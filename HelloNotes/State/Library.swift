//
//  Library.swift
//  HelloNotes
//
//  Created by Chris Tham on 12/7/2026.
//

import Foundation

#if os(macOS)
import AppKit
#endif

/// The workspace: several `Collection`s open at once. The library tracks which
/// collection is *focused* (the one the editor, Git panel, and note-level
/// actions operate on) and persists the set of open collections so they reopen
/// on the next launch. Collections themselves stay isolated — the library only
/// aggregates them for library-wide search and reopening.
@MainActor
@Observable
final class Library {
    /// The collections currently open, in the order they were added.
    private(set) var collections: [Collection] = []

    /// The focused collection's id — drives the editor, Git panel and
    /// note-scoped actions. Defaults to the first collection.
    var focusedID: Collection.ID?

    /// The focused collection (falls back to the first open one).
    var focused: Collection? {
        collections.first { $0.id == focusedID } ?? collections.first
    }

    /// Notes across every open collection (for library-wide search / chat).
    var allNotes: [Note] { collections.flatMap(\.notes) }

    var isEmpty: Bool { collections.isEmpty }

    /// Called when any open collection changes on disk — wired by the view to
    /// reconcile open editors and revalidate the selection.
    var onExternalChange: @MainActor () -> Void = {}

    // MARK: - Focus

    func focus(_ collection: Collection) { focusedID = collection.id }

    /// The collection that contains `fileURL`, if any (matched by path prefix).
    func collection(containing fileURL: URL) -> Collection? {
        let path = fileURL.standardizedFileURL.path
        return collections.first { collection in
            var base = collection.rootURL.standardizedFileURL.path
            if !base.hasSuffix("/") { base += "/" }
            return path == collection.rootURL.standardizedFileURL.path || path.hasPrefix(base)
        }
    }

    /// Focus the collection owning `fileURL` (used when a note is selected).
    func focusCollection(containing fileURL: URL) {
        if let owner = collection(containing: fileURL) { focusedID = owner.id }
    }

    // MARK: - Open / close

    /// Open the folder at `url` as a collection (or focus it if already open),
    /// activate it, and remember it for next launch. Returns the collection.
    @discardableResult
    func open(url: URL) async -> Collection {
        let id = url.standardizedFileURL.path
        if let existing = collections.first(where: { $0.id == id }) {
            focusedID = existing.id
            return existing
        }
        let collection = Collection(rootURL: url)
        collections.append(collection)
        focusedID = collection.id
        await collection.activate(onExternalChange: { [weak self] in self?.onExternalChange() })
        persist()
        return collection
    }

    /// Open several folders at once (multi-select).
    func open(urls: [URL]) async {
        for url in urls { await open(url: url) }
    }

    /// Close a collection: stop watching it, drop it, and update persistence.
    func close(_ collection: Collection) {
        collection.deactivate()
        collections.removeAll { $0.id == collection.id }
        if focusedID == collection.id { focusedID = collections.first?.id }
        persist()
    }

    #if os(macOS)
    /// Present an open panel (multi-select) to add one or more collections.
    func requestOpenCollections() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more folders to open as collections."

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await open(urls: urls) }
    }
    #endif

    // MARK: - Persistence (security-scoped bookmarks)

    private static let bookmarksKey = "collectionBookmarks"
    private static let legacyKey = "vaultBookmark"

    /// Reopen the collections that were open at last quit. Call once at launch.
    func restore() async {
        let store = UserDefaults.standard
        var datas = (store.array(forKey: Self.bookmarksKey) as? [Data]) ?? []

        // Migrate a single legacy vault bookmark into the new list.
        if datas.isEmpty, let legacy = store.data(forKey: Self.legacyKey) {
            datas = [legacy]
            store.removeObject(forKey: Self.legacyKey)
        }

        for data in datas {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data, options: bookmarkResolutionOptions,
                relativeTo: nil, bookmarkDataIsStale: &isStale
            ) else { continue }
            await open(url: url)
        }
    }

    private func persist() {
        let datas: [Data] = collections.compactMap { collection in
            try? collection.rootURL.bookmarkData(
                options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(datas, forKey: Self.bookmarksKey)
    }

    #if os(macOS)
    private var bookmarkCreationOptions: URL.BookmarkCreationOptions { [] }
    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions { [] }
    #else
    private var bookmarkCreationOptions: URL.BookmarkCreationOptions { [] }
    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions { [] }
    #endif
}

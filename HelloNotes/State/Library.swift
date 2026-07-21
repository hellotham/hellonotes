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

    // Cached flattened notes + id→note index, rebuilt only when a collection's
    // structural `revision` changes. `allNotes` used to re-`flatMap` every open
    // collection on each access (read many times per view body), and callers
    // then linearly scanned it to resolve the selected note.
    @ObservationIgnored private var cachedRevision = -1
    @ObservationIgnored private var cachedAllNotes: [Note] = []
    @ObservationIgnored private var cachedIndex: [Note.ID: Note] = [:]

    /// Sum of collection revisions (+ count) — cheap, changes on any note-set change.
    private var aggregateRevision: Int {
        collections.reduce(collections.count) { $0 &+ $1.revision }
    }

    private func refreshCacheIfNeeded() {
        let rev = aggregateRevision
        guard rev != cachedRevision else { return }
        cachedRevision = rev
        var all: [Note] = []
        var index: [Note.ID: Note] = [:]
        for collection in collections {
            all.append(contentsOf: collection.notes)
            for note in collection.notes { index[note.id] = note }
        }
        cachedAllNotes = all
        cachedIndex = index
    }

    /// Notes across every open collection (for library-wide search / chat).
    var allNotes: [Note] {
        refreshCacheIfNeeded()
        return cachedAllNotes
    }

    /// O(1) lookup of a note by id across all collections.
    func note(id: Note.ID?) -> Note? {
        guard let id else { return nil }
        refreshCacheIfNeeded()
        return cachedIndex[id]
    }

    var isEmpty: Bool { collections.isEmpty }

    /// Called when any open collection changes on disk — wired by the view to
    /// reconcile open editors and revalidate the selection.
    var onExternalChange: @MainActor () -> Void = {}

    /// Called with a collection's root URL each time it's opened — wired to the
    /// recents store.
    var onOpened: @MainActor (URL) -> Void = { _ in }

    /// A note another window (graph, mind map, assistant, chat) asked the main
    /// window to select. The main window observes this, selects the note, and
    /// clears it.
    var pendingOpenNoteID: Note.ID?

    /// Ask the main window to select and show `noteID`.
    func requestOpen(_ noteID: Note.ID) { pendingOpenNoteID = noteID }

    // MARK: - Focus

    func focus(_ collection: Collection) { focusedID = collection.id }

    /// The collection that contains `fileURL`, if any (matched by path prefix).
    func collection(containing fileURL: URL) -> Collection? {
        let path = fileURL.standardizedFileURL.path
        return collections.first { collection in
            // `collection.id` is the already-standardised root path — reuse it
            // instead of re-standardising the root on each of the many calls.
            let base = collection.id
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
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
            onOpened(url)
            return existing
        }
        let collection = Collection(rootURL: url)
        collections.append(collection)
        focusedID = collection.id
        await collection.activate(onExternalChange: { [weak self] in self?.onExternalChange() })
        persist()
        onOpened(url)
        return collection
    }

    /// Open several folders at once (multi-select).
    func open(urls: [URL]) async {
        for url in urls { await open(url: url) }
    }

    /// Open a cloud account (a `RemoteStore` folder) as a first-class collection:
    /// mirror it into a local cache, then open that cache with the normal
    /// machinery. Saved edits upload back through `Collection.remote`. Not
    /// persisted for restore — a remote collection is re-opened via its provider,
    /// not a local bookmark whose cache could be stale.
    @discardableResult
    func openRemote(store: RemoteStore, remoteRoot: String, displayName: String) async throws -> Collection {
        let mirror = RemoteMirror(
            store: store,
            cacheRoot: RemoteMirror.cacheDirectory(provider: store.providerName,
                                                   folder: remoteRoot.isEmpty ? displayName : remoteRoot),
            remoteRoot: remoteRoot,
            displayName: displayName)
        try await mirror.syncDown()

        let id = mirror.cacheRoot.standardizedFileURL.path
        if let existing = collections.first(where: { $0.id == id }) {
            existing.remote = mirror
            focusedID = existing.id
            return existing
        }
        let collection = Collection(rootURL: mirror.cacheRoot)
        collection.remote = mirror
        collections.append(collection)
        focusedID = collection.id
        await collection.activate(onExternalChange: { [weak self] in self?.onExternalChange() })
        return collection
    }

    /// Close a collection: stop watching it, drop it, and update persistence.
    func close(_ collection: Collection) {
        collection.deactivate()
        collections.removeAll { $0.id == collection.id }
        if focusedID == collection.id { focusedID = collections.first?.id }
        persist()
    }

    /// Close every open collection (used when switching to a saved library).
    func closeAll() {
        for collection in collections { collection.deactivate() }
        collections.removeAll()
        focusedID = nil
        persist()
    }

    /// Switch to a saved library: close what's open, then open its collections.
    func openLibrary(_ urls: [URL]) async {
        closeAll()
        await open(urls: urls)
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
            guard let url = Bookmark.resolve(data) else { continue }
            await open(url: url)
        }
    }

    private func persist() {
        let datas: [Data] = collections.compactMap { Bookmark.data(for: $0.rootURL) }
        UserDefaults.standard.set(datas, forKey: Self.bookmarksKey)
    }
}

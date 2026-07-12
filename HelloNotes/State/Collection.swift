//
//  Collection.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// One open collection: a local directory (the absolute source of truth) plus
/// everything derived from it — its notes, attachments, `[[wiki-link]]` graph,
/// search index, and its own Git repository and bookmarks. Collections are
/// isolated: links, backlinks and the graph resolve only within a collection.
/// A `Library` holds several collections open at once.
@MainActor
@Observable
final class Collection: Identifiable {
    /// Stable identity — the standardized root path (survives re-indexing and
    /// dedupes a folder opened twice).
    nonisolated let id: String

    /// The folder this collection indexes.
    let rootURL: URL

    /// The collection's display name (its folder name).
    var name: String { rootURL.lastPathComponent }

    /// The Markdown notes discovered inside the collection.
    var notes: [Note] = []

    /// Non-Markdown files (PDFs, images, CSVs, …), browsable alongside notes.
    var attachments: [CollectionFile] = []

    // MARK: Per-collection subsystems (isolated to this collection)

    /// The collection's `[[wiki-link]]` / backlink index.
    let linkGraph = LinkGraph()

    /// Full-text search + fuzzy "Open Quickly" index over this collection.
    let search = CollectionSearchModel()

    /// Git status + operations for this collection's repository.
    let git = GitService()

    /// Bookmarked notes within this collection.
    let bookmarks = BookmarksStore()

    #if os(macOS)
    /// Tells the editor which wiki-link targets exist (drives clickability).
    let wikiResolver = CollectionWikiLinkResolver()

    /// Renders `![[Note]]` transclusions to inline images.
    let embedProvider = CollectionEmbedProvider()

    private var fileWatcher: FileWatcher?
    #endif

    private var securityScoped = false

    /// The Uniform Type Identifier used to recognise Markdown files.
    private static let markdownType: UTType =
        UTType("net.daringfireball.markdown")
        ?? UTType(filenameExtension: "md")
        ?? .plainText

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.id = rootURL.standardizedFileURL.path
        git.rootURL = rootURL
        bookmarks.load(rootURL: rootURL)
    }

    // MARK: - Scanning

    /// Scans `rootURL` for Markdown files and other attachments.
    func scan() {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey, .isRegularFileKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            notes = []
            attachments = []
            return
        }

        var discovered: [Note] = []
        var discoveredFiles: [CollectionFile] = []

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  resourceValues.isRegularFile == true else {
                continue
            }
            let modified = resourceValues.contentModificationDate ?? .distantPast

            let isMarkdown = resourceValues.contentType?.conforms(to: Self.markdownType) == true
                || UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: Self.markdownType) == true

            if isMarkdown {
                discovered.append(Note(
                    title: fileURL.deletingPathExtension().lastPathComponent,
                    fileURL: fileURL,
                    lastModified: modified
                ))
            } else {
                discoveredFiles.append(CollectionFile(url: fileURL, lastModified: modified))
            }
        }

        notes = discovered.sorted { $0.lastModified > $1.lastModified }
        attachments = discoveredFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Lifecycle

    #if os(macOS)
    /// Begin the security scope, do an initial scan, refresh derived data and Git
    /// status, and start watching the folder for external changes.
    func activate(onExternalChange: @escaping @MainActor () -> Void) async {
        securityScoped = rootURL.startAccessingSecurityScopedResource()
        scan()
        refreshDerived()
        await git.refreshStatus()
        startWatching(onExternalChange: onExternalChange)
    }

    /// Stop watching and relinquish the security scope. Call before closing.
    func deactivate() {
        fileWatcher?.stop()
        fileWatcher = nil
        if securityScoped { rootURL.stopAccessingSecurityScopedResource(); securityScoped = false }
    }

    /// Rebuild the wiki-link resolver, embed provider, backlink graph and search
    /// index from the current note set.
    func refreshDerived() {
        wikiResolver.update(titles: notes.map(\.title))
        embedProvider.update(notes: notes)
        Task {
            await linkGraph.rebuild(from: notes)
            await search.refresh(from: notes)
            wikiResolver.update(titles: Array(linkGraph.resolution.keys))
        }
    }

    private func startWatching(onExternalChange: @escaping @MainActor () -> Void) {
        let watcher = FileWatcher { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scan()
                self.refreshDerived()
                onExternalChange()
            }
        }
        watcher.start(url: rootURL)
        fileWatcher = watcher
    }
    #else
    func activate(onExternalChange: @escaping @MainActor () -> Void) async {
        securityScoped = rootURL.startAccessingSecurityScopedResource()
        scan()
        Task { await search.refresh(from: notes) }
    }

    func deactivate() {
        if securityScoped { rootURL.stopAccessingSecurityScopedResource(); securityScoped = false }
    }

    func refreshDerived() {
        Task { await search.refresh(from: notes) }
    }
    #endif

    // MARK: - File operations

    /// Create a new empty Markdown note and return it. The filename is derived
    /// from `title`, disambiguated if it already exists.
    @discardableResult
    func createNote(title: String = "Untitled") -> Note? {
        let fileManager = FileManager.default
        let base = title.isEmpty ? "Untitled" : title
        var candidate = rootURL.appendingPathComponent("\(base).md")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }

        do {
            try Data().write(to: candidate, options: .withoutOverwriting)
        } catch {
            return nil
        }

        scan()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == candidate.standardizedFileURL }
    }

    /// Return the note at `relativePath`, creating the file (and any intermediate
    /// folders) with `content` if it doesn't exist yet. Used for daily notes.
    @discardableResult
    func note(atRelativePath relativePath: String, creatingWith content: @autoclosure () -> String) -> Note? {
        let url = rootURL.appendingPathComponent(relativePath)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try Data(content().utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                return nil
            }
            scan()
            refreshDerived()
        }
        return notes.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// Move a note to the Trash (never a hard delete) and re-index.
    func deleteNote(_ note: Note) {
        try? FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
        scan()
        refreshDerived()
    }
}

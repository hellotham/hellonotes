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

    /// Every directory inside the collection, so empty folders (e.g. one just
    /// created, or one whose last note moved out) still appear in the tree.
    var folders: [URL] = []

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

    /// Standardised paths this collection wrote itself, with when — so the file
    /// watcher can ignore the churn from our own autosaves (and their atomic
    /// temp files) instead of re-scanning the whole collection on every save.
    private var recentSelfWrites: [String: Date] = [:]

    /// Debounced index refresh scheduled after an editor save (the note *set*
    /// is unchanged, so no re-scan is needed — only the content-derived index).
    private var deriveTask: Task<Void, Never>?
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
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey, .isRegularFileKey, .isDirectoryKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            notes = []
            attachments = []
            folders = []
            return
        }

        var discovered: [Note] = []
        var discoveredFiles: [CollectionFile] = []
        var discoveredFolders: [URL] = []

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else {
                continue
            }
            if resourceValues.isDirectory == true {
                discoveredFolders.append(fileURL)
                continue
            }
            guard resourceValues.isRegularFile == true else { continue }
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
        folders = discoveredFolders
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
        let watcher = FileWatcher { [weak self] paths in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.hasExternalChanges(in: paths) else { return }
                self.scan()
                self.refreshDerived()
                onExternalChange()
            }
        }
        watcher.start(url: rootURL)
        fileWatcher = watcher
    }

    /// Whether `paths` contains a change we didn't cause. Filters out our own
    /// recent autosaves and hidden-file churn (atomic-write temp files, the
    /// `.git` directory that auto-commit touches, `.DS_Store`), so the app's own
    /// writes never trigger a full re-scan + re-index of the collection.
    private func hasExternalChanges(in paths: [String]) -> Bool {
        let now = Date()
        recentSelfWrites = recentSelfWrites.filter { now.timeIntervalSince($0.value) < 5 }
        return paths.contains { path in
            if (path as NSString).lastPathComponent.hasPrefix(".") { return false }
            if let wroteAt = recentSelfWrites[Self.normalize(path)],
               now.timeIntervalSince(wroteAt) < 3 { return false }
            return true
        }
    }

    /// Normalise a path for comparison — resolves symlinks and the `/private`
    /// prefix so FSEvents paths and our own write paths match.
    private nonisolated static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Record that the editor just saved `url`, and schedule a debounced refresh
    /// of the content-derived index (links, search, tags). No re-scan: saving a
    /// note's contents doesn't change which notes exist, and the heavy index
    /// work runs off the main actor — so typing never stalls on a vault re-read.
    func noteDidSave(_ url: URL) {
        recentSelfWrites[Self.normalize(url.path)] = Date()
        deriveTask?.cancel()
        deriveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.refreshDerived()
        }
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
    /// from `title`, disambiguated if it already exists. `directory` defaults to
    /// the collection root; pass a subfolder URL to create the note there.
    @discardableResult
    func createNote(title: String = "Untitled", in directory: URL? = nil) -> Note? {
        let fileManager = FileManager.default
        let base = title.isEmpty ? "Untitled" : title
        let folder = directory ?? rootURL
        var candidate = folder.appendingPathComponent("\(base).md")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).md")
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

    /// Rename a note's file to `newTitle` and rewrite every `[[wiki-link]]`
    /// (and `![[embed]]`) across the collection that pointed at the old title,
    /// so renaming never silently breaks links. Returns the renamed note, or
    /// `nil` if the name is empty/unchanged or the destination already exists.
    @discardableResult
    func renameNote(_ note: Note, to newTitle: String) -> Note? {
        let title = newTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !title.isEmpty, title != note.title else { return nil }

        let destination = note.fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(title).md")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: note.fileURL, to: destination)
        } catch {
            return nil
        }

        rewriteWikiLinks(from: note.title, to: title, renamed: note.fileURL, movedTo: destination)
        scan()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == destination.standardizedFileURL }
    }

    /// Duplicate a note beside the original ("Title copy.md", disambiguated)
    /// and return the copy.
    @discardableResult
    func duplicateNote(_ note: Note) -> Note? {
        let folder = note.fileURL.deletingLastPathComponent()
        let base = "\(note.title) copy"
        var candidate = folder.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: note.fileURL, to: candidate)
        } catch {
            return nil
        }
        scan()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == candidate.standardizedFileURL }
    }

    /// Rewrite `[[oldTitle]]`, `[[oldTitle|alias]]`, `[[oldTitle#heading]]` and
    /// their `![[…]]` embed forms to the new title in every note — including the
    /// renamed note itself, whose file has already moved to `movedTo`.
    /// Case-insensitive and whitespace-tolerant; aliases and headings survive.
    private func rewriteWikiLinks(from oldTitle: String, to newTitle: String,
                                  renamed oldURL: URL, movedTo newURL: URL) {
        let escaped = NSRegularExpression.escapedPattern(for: oldTitle)
        guard let regex = try? NSRegularExpression(
            pattern: #"(\[\[)\s*"# + escaped + #"\s*(?=[#|\]])"#,
            options: [.caseInsensitive]
        ) else { return }

        let template = "$1" + NSRegularExpression.escapedTemplate(for: newTitle)
        for other in notes {
            // `notes` is pre-rescan, so the renamed note still lists its old URL.
            let url = other.fileURL == oldURL ? newURL : other.fileURL
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("[[") else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, options: [], range: range) != nil else { continue }
            let updated = regex.stringByReplacingMatches(in: text, options: [], range: range,
                                                         withTemplate: template)
            try? Data(updated.utf8).write(to: url, options: .atomic)
        }
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

    /// Create an empty folder inside `parent` (defaults to the root), with the
    /// name disambiguated if it already exists. Returns the new folder's URL.
    @discardableResult
    func createFolder(named name: String = "New Folder", in parent: URL? = nil) -> URL? {
        let base = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !base.isEmpty else { return nil }
        let container = parent ?? rootURL
        var candidate = container.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = container.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            counter += 1
        }
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        } catch {
            return nil
        }
        scan()
        refreshDerived()
        return candidate
    }

    /// Move a folder (and its contents) to the Trash and re-index.
    func deleteFolder(at url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        scan()
        refreshDerived()
    }

    /// Move a note or attachment file into `folder` (which must be inside the
    /// collection). Returns the item's new URL, or `nil` when the move fails or
    /// a same-named item already exists there.
    func moveItem(at itemURL: URL, into folder: URL) -> URL? {
        let destination = folder.appendingPathComponent(itemURL.lastPathComponent)
        guard destination.standardizedFileURL != itemURL.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: itemURL, to: destination)
        } catch {
            return nil
        }
        scan()
        refreshDerived()
        return destination
    }
}

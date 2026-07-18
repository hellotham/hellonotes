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

    /// Bumped on every `scan()` — a cheap fingerprint of the note/attachment/
    /// folder *set* so views can cache the folder tree and rebuild only when the
    /// structure actually changes, instead of re-deriving it every render.
    private(set) var revision = 0

    /// Bumped whenever the content-derived index (link graph, search) changes,
    /// so views can recompute derived data (e.g. the references panel) only when
    /// it actually changed rather than on every render.
    private(set) var derivedRevision = 0

    // MARK: Per-collection subsystems (isolated to this collection)

    /// The collection's `[[wiki-link]]` / backlink index.
    let linkGraph = LinkGraph()

    /// Full-text search + fuzzy "Open Quickly" index over this collection.
    let search = CollectionSearchModel()

    /// Git status + operations for this collection's repository.
    let git = GitService()

    /// Bookmarked notes within this collection.
    let bookmarks = BookmarksStore()

    /// The last file-operation failure, for the shell to surface as an alert.
    /// A user-initiated create/rename/duplicate/delete/move that fails on disk
    /// (permissions, name collision, sandbox) sets this instead of silently
    /// no-op'ing. Cleared when the shell presents it. (Cross-platform — the note
    /// operations that set it exist on both macOS and iOS.)
    var lastError: String?

    /// Record a user-facing file-operation failure.
    private func report(_ message: String) { lastError = message }

    /// Renders `![[Note]]` transclusions to inline images (cross-platform: the
    /// live editor's block-embed renderer uses it on both macOS and iOS).
    let embedProvider = CollectionEmbedProvider()

    #if os(macOS)
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
    nonisolated private static let markdownType: UTType =
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

    /// Enumerate `rootURL` into notes / attachments / folders. `nonisolated` and
    /// pure so it can run on a background executor — a full directory walk of a
    /// large collection is thousands of `stat` calls that shouldn't block the UI.
    nonisolated static func enumerate(_ rootURL: URL) -> (notes: [Note], attachments: [CollectionFile], folders: [URL]) {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], [], [])
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
                    lastModified: modified,
                    fileSize: resourceValues.fileSize ?? 0
                ))
            } else {
                discoveredFiles.append(CollectionFile(url: fileURL, lastModified: modified))
            }
        }

        return (
            discovered.sorted { $0.lastModified > $1.lastModified },
            discoveredFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            discoveredFolders
        )
    }

    /// Scan synchronously (used by the infrequent, user-initiated file
    /// mutations that need the updated note immediately afterwards).
    func scan() {
        let result = Self.enumerate(rootURL)
        notes = result.notes
        attachments = result.attachments
        folders = result.folders
        revision &+= 1
    }

    /// Scan off the main actor, then apply the results — used for startup and
    /// external-change reconciliation, where a main-thread directory walk of a
    /// large collection would otherwise freeze the UI.
    func scanOffMain() async {
        let root = rootURL
        let result = await Task.detached(priority: .userInitiated) { Self.enumerate(root) }.value
        notes = result.notes
        attachments = result.attachments
        folders = result.folders
        revision &+= 1
    }

    // MARK: - Lifecycle

    #if os(macOS)
    /// Begin the security scope, do an initial scan, refresh derived data and Git
    /// status, and start watching the folder for external changes.
    func activate(onExternalChange: @escaping @MainActor () -> Void) async {
        securityScoped = rootURL.startAccessingSecurityScopedResource()
        await scanOffMain()
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

    /// Bring the derived index (link graph, search, tags) up to date.
    ///
    /// Cache-first: each note's parsed metadata persists in the
    /// ``CollectionIndexCache`` fingerprinted by mtime + size, so only notes
    /// that actually changed since the cache was written are re-read and
    /// re-parsed — on a warm launch that is usually *none*, and the whole
    /// index is live in milliseconds instead of re-reading the collection.
    /// The graph and aggregates are then rebuilt from metadata entirely in
    /// memory, which keeps this correct for every kind of change.
    ///
    /// `force` ignores the cache and re-parses everything (the Rescan command).
    func refreshDerived(force: Bool = false) {
        embedProvider.update(notes: notes)
        let noteList = notes
        let root = rootURL
        deriveTask?.cancel()
        deriveTask = Task {
            let pairs = await Task.detached(priority: .userInitiated) { () -> [(note: Note, record: NoteIndexRecord)] in
                let cached = force ? [:] : (CollectionIndexCache.load(for: root) ?? [:])
                var pairs: [(note: Note, record: NoteIndexRecord)] = []
                var reparsed = 0
                for note in noteList {
                    let rel = CollectionIndexCache.relativePath(of: note.fileURL, in: root)
                    if let record = cached[rel], record.matches(note) {
                        pairs.append((note, record))
                    } else if let text = try? String(contentsOf: note.fileURL, encoding: .utf8) {
                        pairs.append((note, CollectionIndexCache.record(for: note, relativeTo: root, text: text)))
                        reparsed += 1
                    }
                }
                // Persist when anything was re-parsed or notes were removed.
                if reparsed > 0 || pairs.count != cached.count {
                    CollectionIndexCache.save(pairs.map { $0.record }, for: root)
                }
                return pairs
            }.value
            guard !Task.isCancelled else { return }

            linkGraph.load(pairs: pairs)
            search.load(pairs: pairs)
            derivedRevision &+= 1
        }
    }

    /// Rebuild everything from scratch, ignoring the index cache — the safety
    /// valve for when the index ever looks wrong.
    func rescan() {
        CollectionIndexCache.remove(for: rootURL)
        Task {
            await scanOffMain()
            refreshDerived(force: true)
        }
    }

    private func startWatching(onExternalChange: @escaping @MainActor () -> Void) {
        let watcher = FileWatcher { [weak self] paths in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.hasExternalChanges(in: paths) else { return }
                await self.scanOffMain()
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

    /// Record that the editor just saved `url`, and refresh the content-derived
    /// index (links, search, tags) from the in-memory `text` — no re-scan (the
    /// note set is unchanged) and, in the common case, no vault re-read.
    ///
    /// When the note's title and aliases are unchanged, the link graph and
    /// search entry are patched incrementally (O(1 note)). A title/alias change
    /// can alter *other* notes' backlinks, so that falls back to a debounced
    /// full rebuild for correctness.
    func noteDidSave(_ url: URL, text: String) {
        recentSelfWrites[Self.normalize(url.path)] = Date()
        let title = url.deletingPathExtension().lastPathComponent

        if let note = notes.first(where: { $0.fileURL == url }),
           MarkdownParsing.aliases(in: text) == search.aliases(of: url) {
            linkGraph.updateNote(url: url, title: title, text: text)
            search.updateNote(note, text: text)
            embedProvider.update(notes: notes)   // bump so transclusions re-render
            derivedRevision &+= 1
        } else {
            deriveTask?.cancel()
            deriveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                // Re-stat first: the cache diff compares against each note's
                // scanned mtime/size, and this save just changed them on disk —
                // without a fresh scan the edited note would look unchanged and
                // its stale cached metadata would reload.
                await self.scanOffMain()
                self.refreshDerived()
            }
        }
    }
    #else
    func activate(onExternalChange: @escaping @MainActor () -> Void) async {
        securityScoped = rootURL.startAccessingSecurityScopedResource()
        scan()
        embedProvider.update(notes: notes)   // resolve `![[Note]]` transclusions
        Task { await search.refresh(from: notes) }
    }

    func deactivate() {
        if securityScoped { rootURL.stopAccessingSecurityScopedResource(); securityScoped = false }
    }

    func refreshDerived() {
        embedProvider.update(notes: notes)
        Task { await search.refresh(from: notes) }
    }
    #endif

    // MARK: - File operations

    /// Create a new empty Markdown note and return it. The filename is derived
    /// from `title`, disambiguated if it already exists. `directory` defaults to
    /// the collection root; pass a subfolder URL to create the note there.
    @discardableResult
    func createNote(title: String = "Untitled", in directory: URL? = nil) async -> Note? {
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
            report("Couldn't create the note: \(error.localizedDescription)")
            return nil
        }

        await scanOffMain()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == candidate.standardizedFileURL }
    }

    /// Rename a note's file to `newTitle` and rewrite every `[[wiki-link]]`
    /// (and `![[embed]]`) across the collection that pointed at the old title,
    /// so renaming never silently breaks links. Returns the renamed note, or
    /// `nil` if the name is empty/unchanged or the destination already exists.
    @discardableResult
    func renameNote(_ note: Note, to newTitle: String) async -> Note? {
        let title = newTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !title.isEmpty, title != note.title else { return nil }

        let destination = note.fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(title).md")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            report("A note named “\(title)” already exists in this folder.")
            return nil
        }
        do {
            try FileManager.default.moveItem(at: note.fileURL, to: destination)
        } catch {
            report("Couldn't rename the note: \(error.localizedDescription)")
            return nil
        }

        await rewriteWikiLinks(from: note.title, to: title, renamed: note.fileURL, movedTo: destination)
        await scanOffMain()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == destination.standardizedFileURL }
    }

    /// Duplicate a note beside the original ("Title copy.md", disambiguated)
    /// and return the copy.
    @discardableResult
    func duplicateNote(_ note: Note) async -> Note? {
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
            report("Couldn't duplicate the note: \(error.localizedDescription)")
            return nil
        }
        await scanOffMain()
        refreshDerived()
        return notes.first { $0.fileURL.standardizedFileURL == candidate.standardizedFileURL }
    }

    /// Rewrite `[[oldTitle]]`, `[[oldTitle|alias]]`, `[[oldTitle#heading]]` and
    /// their `![[…]]` embed forms to the new title in every note — including the
    /// renamed note itself, whose file has already moved to `movedTo`.
    /// Case-insensitive and whitespace-tolerant; aliases and headings survive.
    private func rewriteWikiLinks(from oldTitle: String, to newTitle: String,
                                  renamed oldURL: URL, movedTo newURL: URL) async {
        // `notes` is pre-rescan, so the renamed note still lists its old URL.
        let urls = notes.map { $0.fileURL == oldURL ? newURL : $0.fileURL }
        // Read + rewrite every note off the main actor — it's O(N) file I/O.
        // Collect the notes we couldn't rewrite so the shell can tell the user
        // exactly which links may now be stale, rather than failing silently.
        let failures: [String] = await Task.detached(priority: .userInitiated) {
            let escaped = NSRegularExpression.escapedPattern(for: oldTitle)
            guard let regex = try? NSRegularExpression(
                pattern: #"(\[\[)\s*"# + escaped + #"\s*(?=[#|\]])"#,
                options: [.caseInsensitive]
            ) else { return [] }
            let template = "$1" + NSRegularExpression.escapedTemplate(for: newTitle)
            var failed: [String] = []
            for url in urls {
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains("[[") else { continue }
                let range = NSRange(text.startIndex..., in: text)
                guard regex.firstMatch(in: text, options: [], range: range) != nil else { continue }
                let updated = regex.stringByReplacingMatches(in: text, options: [], range: range,
                                                             withTemplate: template)
                do {
                    try Data(updated.utf8).write(to: url, options: .atomic)
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
            return failed
        }.value

        if !failures.isEmpty {
            let list = failures.prefix(5).joined(separator: ", ")
            let more = failures.count > 5 ? " and \(failures.count - 5) more" : ""
            report("Renamed the note, but couldn't update links in \(failures.count) note\(failures.count == 1 ? "" : "s") (\(list)\(more)). Those links may now be broken.")
        }
    }

    /// Return the note at `relativePath`, creating the file (and any intermediate
    /// folders) with `content` if it doesn't exist yet. Used for daily notes.
    @discardableResult
    func note(atRelativePath relativePath: String, creatingWith content: @autoclosure () -> String) async -> Note? {
        let url = rootURL.appendingPathComponent(relativePath)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try Data(content().utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                report("Couldn't create “\(relativePath)”: \(error.localizedDescription)")
                return nil
            }
            await scanOffMain()
            refreshDerived()
        }
        return notes.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// Move a note to the Trash (never a hard delete) and re-index.
    func deleteNote(_ note: Note) async {
        do {
            try FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
        } catch {
            report("Couldn't move “\(note.title)” to the Trash: \(error.localizedDescription)")
        }
        await scanOffMain()
        refreshDerived()
    }

    /// Create an empty folder inside `parent` (defaults to the root), with the
    /// name disambiguated if it already exists. Returns the new folder's URL.
    @discardableResult
    func createFolder(named name: String = "New Folder", in parent: URL? = nil) async -> URL? {
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
            report("Couldn't create the folder: \(error.localizedDescription)")
            return nil
        }
        await scanOffMain()
        refreshDerived()
        return candidate
    }

    /// Move a folder (and its contents) to the Trash and re-index.
    func deleteFolder(at url: URL) async {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            report("Couldn't move the folder to the Trash: \(error.localizedDescription)")
        }
        await scanOffMain()
        refreshDerived()
    }

    /// Move a note or attachment file into `folder` (which must be inside the
    /// collection). Returns the item's new URL, or `nil` when the move fails or
    /// a same-named item already exists there.
    func moveItem(at itemURL: URL, into folder: URL) async -> URL? {
        let destination = folder.appendingPathComponent(itemURL.lastPathComponent)
        guard destination.standardizedFileURL != itemURL.standardizedFileURL else { return nil }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            report("“\(itemURL.lastPathComponent)” already exists in that folder.")
            return nil
        }
        do {
            try FileManager.default.moveItem(at: itemURL, to: destination)
        } catch {
            report("Couldn't move “\(itemURL.lastPathComponent)”: \(error.localizedDescription)")
            return nil
        }
        await scanOffMain()
        refreshDerived()
        return destination
    }
}

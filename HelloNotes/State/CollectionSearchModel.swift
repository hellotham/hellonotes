//
//  CollectionSearchModel.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Observation

/// A full-text search hit: the note plus a snippet around the first match.
struct SearchHit: Identifiable, Hashable {
    var id: URL { note.fileURL }
    let note: Note
    let snippet: String
}

/// An "Open Quickly" candidate — a note, or a heading within a note.
struct QuickOpenItem: Identifiable, Hashable {
    enum Kind: Hashable { case note, heading }
    let id: String
    let note: Note
    let kind: Kind
    let title: String
    let subtitle: String?
    var score: Int = 0
}

/// Indexes note *metadata* (headings, tags, aliases) so the UI can run tag
/// browsing, fuzzy "Open Quickly" lookups and title search over the whole
/// collection instantly. Note *content* is deliberately not kept in memory —
/// on a multi-hundred-megabyte collection that alone dominated the app's
/// footprint. Content search reads only the files it needs, on demand, off
/// the main actor (with Spotlight narrowing the candidates on macOS).
@MainActor
@Observable
final class CollectionSearchModel {
    private struct Entry {
        let note: Note
        let headings: [DocumentHeading]
        let tags: [String]
        let aliases: [String]
    }

    private var entries: [Entry] = []

    // Derived aggregates, computed once per `refresh` and served from the cache.
    // They used to be rebuilt over all entries on every call — and each is read
    // several times per sidebar/editor render (`allTags` 3×), i.e. per keystroke.
    private var cachedTags: [String] = []
    private var cachedTagTree: [TagNode] = []
    private var cachedLinkTargets: [String] = []
    private var cachedItems: [QuickOpenItem] = []
    /// Entries keyed by URL, so per-note lookups (aliases on the selection
    /// and save paths) are O(1) instead of a linear scan of every entry.
    private var entryByURL: [URL: Entry] = [:]

    /// Reload the metadata index from the current notes. Reads files off-main
    /// to parse them; the text itself is discarded after parsing.
    func refresh(from notes: [Note]) async {
        let urls = notes.map(\.fileURL)
        let noteByURL = Dictionary(notes.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

        let loaded = await Task.detached(priority: .utility) { () -> [(URL, [DocumentHeading], [String], [String])] in
            urls.compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let parsed = CollectionIndexCache.parse(text)
                return (url, parsed.headings, parsed.tags, parsed.aliases)
            }
        }.value

        entries = loaded.compactMap { url, headings, tags, aliases in
            noteByURL[url].map { Entry(note: $0, headings: headings, tags: tags, aliases: aliases) }
        }
        rebuildAggregates()
    }

    /// Populate the index from already-parsed metadata (the persistent index
    /// cache) — no file reads at all.
    func load(pairs: [(note: Note, record: NoteIndexRecord)]) {
        entries = pairs.map { note, record in
            Entry(note: note,
                  headings: record.headings,
                  tags: record.tags,
                  aliases: record.aliases)
        }
        rebuildAggregates()
    }

    /// Recompute the cached tag / link-target aggregates from `entries`.
    private func rebuildAggregates() {
        entryByURL = Dictionary(entries.map { ($0.note.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
        cachedTags = Set(entries.flatMap(\.tags))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cachedTagTree = TagTree.build(from: cachedTags)
        var seen = Set<String>()
        cachedLinkTargets = entries
            .flatMap { [$0.note.title] + $0.aliases }
            .filter { seen.insert($0.lowercased()).inserted }
        cachedItems = buildItems()
    }

    /// All distinct hashtags across the collection, sorted case-insensitively.
    func allTags() -> [String] { cachedTags }

    /// The collection's hashtags as a hierarchical tree (`a/b` nests `b` under `a`).
    func tagTree() -> [TagNode] { cachedTagTree }

    /// All note titles plus their aliases — the candidate targets a
    /// `[[wiki-link]]` can point at.
    func linkTargets() -> [String] { cachedLinkTargets }

    /// Notes tagged with `tag` or any of its nested children (case-insensitive):
    /// selecting `project` also matches notes tagged `project/hellonotes`.
    func notesTagged(_ tag: String) -> [Note] {
        let needle = tag.lowercased()
        let prefix = needle + "/"
        return entries
            .filter { entry in
                entry.tags.contains { t in
                    let lower = t.lowercased()
                    return lower == needle || lower.hasPrefix(prefix)
                }
            }
            .map(\.note)
    }

    /// The cached aliases of the note at `url` (before any pending save).
    func aliases(of url: URL) -> [String] {
        entryByURL[url]?.aliases ?? []
    }

    /// Replace (or insert) the indexed entry for `note` from its in-memory text —
    /// no disk read. Used to keep the index fresh after a save without
    /// re-reading the whole collection.
    func updateNote(_ note: Note, text: String) {
        let parsed = CollectionIndexCache.parse(text)
        let entry = Entry(note: note,
                          headings: parsed.headings,
                          tags: parsed.tags,
                          aliases: parsed.aliases)
        if let i = entries.firstIndex(where: { $0.note.fileURL == note.fileURL }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        // Patch the O(1) lookup immediately (it backs `aliases(of:)` and the
        // save path), but debounce the O(collection) aggregate rebuild (tags,
        // tag tree, link targets, quick-open items) so a burst of edits across
        // notes coalesces into one rebuild instead of one per autosave.
        entryByURL[note.fileURL] = entry
        scheduleAggregateRebuild()
    }

    @ObservationIgnored private var aggregateRebuildTask: Task<Void, Never>?

    private func scheduleAggregateRebuild() {
        aggregateRebuildTask?.cancel()
        aggregateRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.rebuildAggregates()
        }
    }

    /// Heading titles of the note named `name` (matched by title or alias),
    /// for `[[Note#heading]]` autocomplete.
    func headings(forName name: String) -> [String] {
        let needle = name.lowercased()
        guard let entry = entries.first(where: {
            $0.note.title.lowercased() == needle || $0.aliases.contains { $0.lowercased() == needle }
        }) else { return [] }
        return entry.headings.map(\.title)
    }

    // MARK: - Search

    /// Notes whose title or alias contains `query` (case-insensitive). Served
    /// entirely from metadata — instant, no file reads.
    func titleResults(query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return entries.compactMap { entry in
            guard entry.note.title.localizedCaseInsensitiveContains(q)
                || entry.aliases.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            else { return nil }
            return SearchHit(note: entry.note, snippet: "")
        }
    }

    /// Notes whose *content* contains `query`, each with a snippet around the
    /// first match. Reads files off the main actor:
    /// - `candidates` non-nil (Spotlight already narrowed the set): reads only
    ///   those files — a handful of reads per query.
    /// - `candidates` nil: scans every indexed note — the correctness fallback
    ///   for volumes without a Spotlight index (and the iOS path).
    func contentResults(query: String, in candidates: [URL]? = nil, limit: Int = 250) async -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let noteByURL = Dictionary(entries.map { ($0.note.fileURL, $0.note) },
                                   uniquingKeysWith: { first, _ in first })
        let urls: [URL]
        if let candidates {
            let indexed = Set(noteByURL.keys)
            urls = candidates.filter { indexed.contains($0) }
        } else {
            urls = entries.map(\.note.fileURL)
        }
        guard !urls.isEmpty else { return [] }

        let found = await Task.detached(priority: .userInitiated) { () -> [(URL, String)] in
            var hits: [(URL, String)] = []
            for url in urls {
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let snippet = Self.snippet(of: text, matching: q) else { continue }
                hits.append((url, snippet))
                if hits.count >= limit { break }
            }
            return hits
        }.value

        return found.compactMap { url, snippet in
            noteByURL[url].map { SearchHit(note: $0, snippet: snippet) }
        }
    }

    /// Title and content hits combined (content snippets win), across the whole
    /// collection. Convenience for retrieval callers (Ask Library, agent tools)
    /// that want one correct answer and can afford the on-demand reads.
    func fullTextResults(query: String) async -> [SearchHit] {
        let content = await contentResults(query: query)
        let contentURLs = Set(content.map(\.id))
        return content + titleResults(query: query).filter { !contentURLs.contains($0.id) }
    }

    /// Fuzzy matches over note titles and their headings, best first.
    func quickOpenResults(query: String, limit: Int = 40) -> [QuickOpenItem] {
        let items = cachedItems
        let q = query.trimmingCharacters(in: .whitespaces)

        guard !q.isEmpty else {
            // Each alias is its own `.note` item (for query matching), so the
            // unfiltered browse list must dedup by the underlying note — otherwise
            // a note with N aliases appears N+1 times.
            var seen = Set<String>()
            let notes = items.filter { $0.kind == .note && seen.insert($0.note.fileURL.path).inserted }
            return Array(notes.prefix(limit))
        }

        let scored = items.compactMap { item -> QuickOpenItem? in
            let haystack = item.subtitle.map { "\(item.title) \($0)" } ?? item.title
            guard let score = FuzzyMatch.score(query: q, candidate: haystack) else { return nil }
            var copy = item
            copy.score = score
            return copy
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Private

    /// The full candidate set (notes + aliases + headings), built once per
    /// `refresh` and cached — it was rebuilt on every Open-Quickly keystroke.
    private func buildItems() -> [QuickOpenItem] {
        entries.flatMap { entry -> [QuickOpenItem] in
            var items = [QuickOpenItem(
                id: entry.note.fileURL.path,
                note: entry.note,
                kind: .note,
                title: entry.note.title,
                subtitle: nil
            )]
            for alias in entry.aliases {
                items.append(QuickOpenItem(
                    id: "\(entry.note.fileURL.path)|alias|\(alias)",
                    note: entry.note,
                    kind: .note,
                    title: entry.note.title,
                    subtitle: "alias: \(alias)"
                ))
            }
            for heading in entry.headings {
                items.append(QuickOpenItem(
                    id: "\(entry.note.fileURL.path)#\(heading.title)",
                    note: entry.note,
                    kind: .heading,
                    title: entry.note.title,
                    subtitle: heading.title
                ))
            }
            return items
        }
    }

    private nonisolated static func snippet(of text: String, matching query: String, context: Int = 40) -> String? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let lower = text.index(range.lowerBound, offsetBy: -context, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: context, limitedBy: text.endIndex) ?? text.endIndex

        var snippet = String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if lower > text.startIndex { snippet = "…" + snippet }
        if upper < text.endIndex { snippet += "…" }
        return snippet
    }
}

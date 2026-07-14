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

/// Caches note contents (and their headings) so the UI can run full-text
/// search and fuzzy "Open Quickly" lookups over the whole collection without
/// re-reading the disk on every keystroke. The cache is refreshed off the
/// main actor whenever the note set or a note's contents change.
@MainActor
@Observable
final class CollectionSearchModel {
    private struct Entry {
        let note: Note
        let text: String
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

    /// Reload the content cache from the current notes (reads files off-main).
    func refresh(from notes: [Note]) async {
        let urls = notes.map(\.fileURL)
        let noteByURL = Dictionary(notes.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

        let loaded = await Task.detached(priority: .utility) { () -> [(URL, String, [DocumentHeading], [String], [String])] in
            urls.compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url, text, MarkdownParsing.headings(in: text), MarkdownParsing.tags(in: text), MarkdownParsing.aliases(in: text))
            }
        }.value

        entries = loaded.compactMap { url, text, headings, tags, aliases in
            noteByURL[url].map { Entry(note: $0, text: text, headings: headings, tags: tags, aliases: aliases) }
        }
        rebuildAggregates()
    }

    /// Recompute the cached tag / link-target aggregates from `entries`.
    private func rebuildAggregates() {
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

    /// Notes that mention `note` by title/alias as plain text without linking it.
    /// `excluding` skips notes that already link it (shown as backlinks instead).
    func unlinkedMentions(of note: Note, names: [String], excluding: Set<URL>) -> [Note] {
        entries.compactMap { entry in
            guard entry.note.fileURL != note.fileURL,
                  !excluding.contains(entry.note.fileURL),
                  MentionScanner.containsMention(of: names, in: entry.text) else { return nil }
            return entry.note
        }
    }

    /// The cached text of a note, if indexed (used to derive its aliases, etc.).
    func text(of note: Note) -> String? {
        entries.first { $0.note.fileURL == note.fileURL }?.text
    }

    /// The cached aliases of the note at `url` (before any pending save).
    func aliases(of url: URL) -> [String] {
        entries.first { $0.note.fileURL == url }?.aliases ?? []
    }

    /// Replace (or insert) the cached entry for `note` from its in-memory text —
    /// no disk read. Used to keep the index fresh after a save without
    /// re-reading the whole collection.
    func updateNote(_ note: Note, text: String) {
        let entry = Entry(note: note, text: text,
                          headings: MarkdownParsing.headings(in: text),
                          tags: MarkdownParsing.tags(in: text),
                          aliases: MarkdownParsing.aliases(in: text))
        if let i = entries.firstIndex(where: { $0.note.fileURL == note.fileURL }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        rebuildAggregates()
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

    /// Notes whose title or body contains `query` (case-insensitive), each with
    /// a snippet around the first body match.
    func fullTextResults(query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        return entries.compactMap { entry in
            if let snippet = Self.snippet(of: entry.text, matching: q) {
                return SearchHit(note: entry.note, snippet: snippet)
            }
            if entry.note.title.localizedCaseInsensitiveContains(q) {
                return SearchHit(note: entry.note, snippet: "")
            }
            return nil
        }
    }

    /// Fuzzy matches over note titles and their headings, best first.
    func quickOpenResults(query: String, limit: Int = 40) -> [QuickOpenItem] {
        let items = cachedItems
        let q = query.trimmingCharacters(in: .whitespaces)

        guard !q.isEmpty else {
            return Array(items.filter { $0.kind == .note }.prefix(limit))
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

    private static func snippet(of text: String, matching query: String, context: Int = 40) -> String? {
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

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
    private struct Entry: Sendable {
        let note: Note
        let headings: [DocumentHeading]
        let tags: [String]
        let aliases: [String]
    }

    // `entries` / `entryByURL` back on-demand query methods (title search,
    // notesTagged, aliases-of). They are `@ObservationIgnored`: nothing
    // reactive reads them directly, and — critically — an index rebuild must
    // be able to swap them in without waking any view. The *reactive* surface
    // is the four `cached*` aggregates below.
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var entryByURL: [URL: Entry] = [:]

    // Derived aggregates — the only observable state. Each is written only when
    // it actually changed (see `apply`), so a rebuild whose result is identical
    // never invalidates the sidebar's tag tree or anything else.
    private var cachedTags: [String] = []
    private var cachedTagTree: [TagNode] = []
    private var cachedLinkTargets: [String] = []
    private var cachedItems: [QuickOpenItem] = []

    /// Hash of the last-applied searchable metadata (per-note tags, title,
    /// aliases, headings). An off-main rebuild whose signature matches this
    /// skips the main-actor assignment entirely — so a co-editor rewriting a
    /// note's *body* (which changes none of that) costs the editor thread
    /// nothing at all.
    @ObservationIgnored private var aggregateSignature = 0

    /// Reload the metadata index from the current notes. Reads files off-main
    /// to parse them; the text itself is discarded after parsing.
    func refresh(from notes: [Note]) async {
        let urls = notes.map(\.fileURL)
        let noteByURL = Dictionary(notes.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })

        // Read the files AND fold them into the derived aggregates entirely off
        // the main actor — the editor thread never sees this work.
        let derived = await offMain { () -> Derived in
            let entries: [Entry] = urls.compactMap { url in
                // Skip files whose content isn't local so metadata indexing never
                // downloads a whole cloud vault — and never mistakes a mirror
                // placeholder for an empty note. They're indexed once hydrated.
                guard let note = noteByURL[url], FileIO.hasContentAvailable(note),
                      let text = try? FileIO.readString(at: url) else { return nil }
                let parsed = CollectionIndexCache.parse(text)
                return Entry(note: note, headings: parsed.headings,
                             tags: parsed.tags, aliases: parsed.aliases)
            }
            return CollectionSearchModel.computeDerived(from: entries)
        }

        apply(derived, replacingEntries: true)
    }

    /// Populate the index from already-parsed metadata (the persistent index
    /// cache) — no file reads. The fold into aggregates runs off the main
    /// actor; the main actor only receives the finished, signature-gated result.
    func load(pairs: [(note: Note, record: NoteIndexRecord)]) async {
        let derived = await Task.detached(priority: .utility) { () -> Derived in
            let entries = pairs.map { pair in
                Entry(note: pair.note,
                      headings: pair.record.headings,
                      tags: pair.record.tags,
                      aliases: pair.record.aliases)
            }
            return CollectionSearchModel.computeDerived(from: entries)
        }.value
        apply(derived, replacingEntries: true)
    }

    /// The off-main product of an index rebuild — everything the model serves,
    /// computed away from the main actor so it never competes with typing.
    private struct Derived: Sendable {
        var entries: [Entry]
        var entryByURL: [URL: Entry]
        var tags: [String]
        var tagTree: [TagNode]
        var linkTargets: [String]
        var items: [QuickOpenItem]
        var signature: Int
    }

    /// Pure and `nonisolated`, so it runs on a background executor: data in,
    /// data out, no actor state and no I/O. This is the O(collection) work —
    /// tag set, tag tree, link targets, quick-open items — kept off the editor
    /// thread.
    private nonisolated static func computeDerived(from entries: [Entry]) -> Derived {
        let entryByURL = Dictionary(entries.map { ($0.note.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
        let tags = Set(entries.flatMap(\.tags))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let tagTree = TagTree.build(from: tags)
        var seen = Set<String>()
        let linkTargets = entries
            .flatMap { [$0.note.title] + $0.aliases }
            .filter { seen.insert($0.lowercased()).inserted }
        let items = buildItems(from: entries)

        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry.note.fileURL)
            hasher.combine(entry.note.title)
            hasher.combine(entry.tags)
            hasher.combine(entry.aliases)
            hasher.combine(entry.headings)
        }
        return Derived(entries: entries, entryByURL: entryByURL, tags: tags,
                       tagTree: tagTree, linkTargets: linkTargets, items: items,
                       signature: hasher.finalize())
    }

    /// Hand an off-main rebuild's result to the main actor. This is the ONLY
    /// main-thread step, and it is O(1) in the common case: if the searchable
    /// signature is unchanged, it returns before touching any observable state.
    /// When something did change, each cache is still written only if it
    /// differs, so the sidebar's tag `ForEach` re-renders only on real change.
    private func apply(_ derived: Derived, replacingEntries: Bool) {
        // Cheap (buffer retain) and non-observed, so it never wakes a view.
        if replacingEntries {
            entries = derived.entries
            entryByURL = derived.entryByURL
        }
        guard derived.signature != aggregateSignature else { return }
        aggregateSignature = derived.signature
        if derived.tags != cachedTags {
            cachedTags = derived.tags
            cachedTagTree = derived.tagTree
        }
        if derived.linkTargets != cachedLinkTargets { cachedLinkTargets = derived.linkTargets }
        if derived.items != cachedItems { cachedItems = derived.items }
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
        // Snapshot the live entries (O(1) COW). `updateNote` already patched
        // them and the O(1) lookup synchronously, so queries are correct
        // immediately; only the O(collection) aggregate fold is deferred —
        // and it runs off the main actor, so the editor thread is never
        // blocked by it.
        let snapshot = entries
        aggregateRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let derived = await Task.detached(priority: .utility) {
                CollectionSearchModel.computeDerived(from: snapshot)
            }.value
            guard !Task.isCancelled, let self else { return }
            // Entries are maintained live by `updateNote`; only fold in the
            // aggregates (signature-gated, so unchanged metadata is a no-op).
            self.apply(derived, replacingEntries: false)
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

        let notesByURL = Dictionary(entries.map { ($0.note.fileURL, $0.note) },
                                    uniquingKeysWith: { first, _ in first })
        let found = await Task.detached(priority: .userInitiated) { () -> [(URL, String)] in
            var hits: [(URL, String)] = []
            for url in urls {
                // Full-text search reads bodies; skip files whose content isn't
                // local so a query never silently downloads the vault, nor
                // matches nothing against a placeholder. Title/tag/alias search
                // (metadata) still covers them.
                guard let note = notesByURL[url], FileIO.hasContentAvailable(note),
                      let text = try? FileIO.readString(at: url),
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
    private nonisolated static func buildItems(from entries: [Entry]) -> [QuickOpenItem] {
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

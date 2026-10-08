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
///
/// `nonisolated`, as the index's other types are: the aggregate fold builds
/// these off the main actor (`buildItems`), and in this target an unannotated
/// type is `@MainActor` — clean only while the fold touched nothing but stored
/// properties. One computed member more and the fold would have been reading
/// main-actor state off the main actor: not a hop — a synchronous body cannot
/// hop — but an unchecked race the compiler could only warn about.
nonisolated struct QuickOpenItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case note, heading }
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
    /// `nonisolated`, like `Derived` and `QuickOpenItem`: the folds below build
    /// and read these off the main actor.
    private nonisolated struct Entry: Sendable {
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
    /// Where each note's entry is in `entries`, so a save finds its own
    /// without a pass over the collection: a burst — a rename's rewrite saves
    /// one note per backlink — was a pass per save, quadratic in the burst.
    @ObservationIgnored private var positionByURL: [URL: Int] = [:]

    // Derived aggregates — the only observable state. Each is written only when
    // it actually changed (see `apply`), so a rebuild whose result is identical
    // never invalidates the sidebar's tag tree or anything else.
    private var cachedTags: [String] = []
    private var cachedTagCounts: [String: Int] = [:]
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
        // `offMain`, as `refresh(from:)` has: `Task.detached` promises nothing
        // about isolation in this target.
        let derived = await offMain { () -> Derived in
            let entries = pairs.map { pair in
                Entry(note: pair.note,
                      headings: pair.record.headings,
                      tags: pair.record.tags,
                      aliases: pair.record.aliases)
            }
            return CollectionSearchModel.computeDerived(from: entries)
        }
        // A rebuild replaced by a newer one while this was computed must not
        // land after it: the two computations finish in either order.
        guard !Task.isCancelled else { return }
        apply(derived, replacingEntries: true)
    }

    /// The off-main product of an index rebuild — everything the model serves,
    /// computed away from the main actor so it never competes with typing.
    private nonisolated struct Derived: Sendable {
        var entries: [Entry]
        var entryByURL: [URL: Entry]
        var position: [URL: Int]
        var tags: [String]
        /// How many notes carry each tag, lowercased, or a tag under it.
        var tagCounts: [String: Int]
        var linkTargets: [String]
        var items: [QuickOpenItem]
        var signature: Int
    }

    /// Pure and `nonisolated`, so it runs on a background executor: data in,
    /// data out, no actor state and no I/O. This is the O(collection) work —
    /// tag set, tag counts, link targets, quick-open items — kept off the editor
    /// thread.
    private nonisolated static func computeDerived(from entries: [Entry]) -> Derived {
        let entryByURL = Dictionary(entries.map { ($0.note.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
        let position = Dictionary(entries.indices.map { (entries[$0].note.fileURL, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let tags = Set(entries.flatMap(\.tags))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // Each note counted once for each tag it carries and every tag above
        // one — `a/b/c` is carried by `a`, `a/b` and `a/b/c` — as `carries`
        // reads it, so a count is a lookup.
        var tagCounts: [String: Int] = [:]
        for entry in entries {
            var carried = Set<String>()
            for tag in entry.tags {
                var above = ""
                for part in tag.lowercased().split(separator: "/", omittingEmptySubsequences: false) {
                    above = above.isEmpty ? String(part) : above + "/" + part
                    carried.insert(above)
                }
            }
            for tag in carried { tagCounts[tag, default: 0] += 1 }
        }
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
        return Derived(entries: entries, entryByURL: entryByURL, position: position, tags: tags,
                       tagCounts: tagCounts, linkTargets: linkTargets, items: items,
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
            positionByURL = derived.position
            // A fold still waiting was of the entries just replaced: landing
            // after this, it would put their tags, link targets and Open
            // Quickly items back over these. A patch made while this was
            // built is the caller's to make again (`Collection.refreshDerived`).
            aggregateRebuildTask?.cancel()
            aggregateRebuildTask = nil
        }
        guard derived.signature != aggregateSignature else { return }
        aggregateSignature = derived.signature
        if derived.tags != cachedTags { cachedTags = derived.tags }
        if derived.tagCounts != cachedTagCounts { cachedTagCounts = derived.tagCounts }
        if derived.linkTargets != cachedLinkTargets { cachedLinkTargets = derived.linkTargets }
        if derived.items != cachedItems { cachedItems = derived.items }
    }

    /// All distinct hashtags across the collection, sorted case-insensitively.
    func allTags() -> [String] { cachedTags }

    /// All note titles plus their aliases — the candidate targets a
    /// `[[wiki-link]]` can point at.
    func linkTargets() -> [String] { cachedLinkTargets }

    /// Notes tagged with `tag` or any of its nested children (case-insensitive):
    /// selecting `project` also matches notes tagged `project/hellonotes`.
    func notesTagged(_ tag: String) -> [Note] {
        entries.filter(carries(tag)).map(\.note)
    }

    /// How many notes `notesTagged` would return — a lookup in the counts the
    /// index folds off the main actor.
    ///
    /// The Tags view asks this for every matching tag in its body, at each
    /// pause in typing, and it walked every note per tag: 4 ms for 223 tags
    /// over 2,027 notes, 40 ms at five tags a note (implemented.md §51.36).
    /// The fold follows a save a quarter of a second behind, as the tag list
    /// itself does.
    func noteCountTagged(_ tag: String) -> Int {
        cachedTagCounts[tag.lowercased()] ?? 0
    }

    /// One definition of "carries this tag", so the list and the count can
    /// never drift apart about what is being counted.
    private func carries(_ tag: String) -> (Entry) -> Bool {
        let needle = tag.lowercased()
        let prefix = needle + "/"
        return { entry in
            entry.tags.contains { t in
                let lower = t.lowercased()
                return lower == needle || lower.hasPrefix(prefix)
            }
        }
    }

    /// The cached aliases of the note at `url` (before any pending save).
    func aliases(of url: URL) -> [String] {
        entryByURL[url]?.aliases ?? []
    }

    /// Replace (or insert) the indexed entry for `note` from what its text was
    /// parsed to — by a save, off the main actor (`Collection.indexSaved`) —
    /// with no disk read and no parse, to keep the index fresh after a save
    /// without re-reading the whole collection.
    func updateNote(_ note: Note, headings: [DocumentHeading], tags: [String], aliases: [String]) {
        patch(Entry(note: note, headings: headings, tags: tags, aliases: aliases))
        // Patch the O(1) lookups immediately (they back `aliases(of:)` and the
        // save path), but debounce the O(collection) aggregate rebuild (tags,
        // tag tree, link targets, quick-open items) so a burst of edits across
        // notes coalesces into one rebuild instead of one per autosave.
        scheduleAggregateRebuild()
    }

    /// `updateNote` for several notes at once, folded once.
    func updateNotes(_ updates: [(note: Note, headings: [DocumentHeading], tags: [String], aliases: [String])]) {
        guard !updates.isEmpty else { return }
        for update in updates {
            patch(Entry(note: update.note, headings: update.headings, tags: update.tags, aliases: update.aliases))
        }
        scheduleAggregateRebuild()
    }

    /// Replace the note's entry, or add it.
    private func patch(_ entry: Entry) {
        let url = entry.note.fileURL
        if let i = positionByURL[url] {
            entries[i] = entry
        } else {
            positionByURL[url] = entries.count
            entries.append(entry)
        }
        entryByURL[url] = entry
    }

    @ObservationIgnored private var aggregateRebuildTask: Task<Void, Never>?

    private func scheduleAggregateRebuild() {
        aggregateRebuildTask?.cancel()
        aggregateRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            // Snapshot the live entries (O(1) COW) once the edits have
            // paused. `updateNote` already patched them and the O(1) lookup
            // synchronously, so queries are correct immediately; only the
            // O(collection) aggregate fold is deferred — and it runs off the
            // main actor, so the editor thread is never blocked by it. Taken
            // when the fold was scheduled instead, the snapshot shared the
            // array through the wait, and every patch in a burst — a rename's
            // rewrite saves one note per backlink — copied all of it.
            guard !Task.isCancelled, let snapshot = self?.entries else { return }
            let derived = await offMain {
                CollectionSearchModel.computeDerived(from: snapshot)
            }
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

    /// Notes whose title or alias contains `query`. Served entirely from
    /// metadata — instant, no file reads.
    ///
    /// `localizedStandardContains`, not `localizedCaseInsensitiveContains`:
    /// searching is user-facing text matching, so it should fold diacritics and
    /// character width as well as case. Typing `cafe` has to find `Café`.
    func titleResults(query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return entries.compactMap { entry in
            guard entry.note.title.localizedStandardContains(q)
                || entry.aliases.contains(where: { $0.localizedStandardContains(q) })
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

        // Built once and handed to the reads as it is: the same dictionary
        // was built a second time, on the main actor, for every query.
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

        let found = await offMain { () -> [(URL, String)] in
            var hits: [(URL, String)] = []
            for url in urls {
                // Full-text search reads bodies; skip files whose content isn't
                // local so a query never silently downloads the vault, nor
                // matches nothing against a placeholder. Title/tag/alias search
                // (metadata) still covers them.
                guard let note = noteByURL[url], FileIO.hasContentAvailable(note),
                      let text = try? FileIO.readString(at: url),
                      let snippet = Self.snippet(of: text, matching: q) else { continue }
                hits.append((url, snippet))
                if hits.count >= limit { break }
            }
            return hits
        }

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

    /// Fuzzy matches over note titles and their headings, best first — scored
    /// on the caller's actor, for a caller not waiting on a keystroke (an
    /// intent). The palette uses `quickOpenResultsOffMain`.
    func quickOpenResults(query: String, limit: Int = 40) -> [QuickOpenItem] {
        Self.rank(cachedItems, query: query, limit: limit)
    }

    /// The same, scored **off the main actor**. Every note, alias and heading
    /// is scored per query — about 20,000 items in a large vault — at each
    /// pause in typing in Open Quickly, and it was scored on the main actor
    /// (implemented.md §51.36).
    func quickOpenResultsOffMain(query: String, limit: Int = 40) async -> [QuickOpenItem] {
        let items = cachedItems
        return await offMain { Self.rank(items, query: query, limit: limit) }
    }

    /// `items` that match `query`, best first, at most `limit` — or, with no
    /// query, the first `limit` notes once each.
    nonisolated static func rank(_ items: [QuickOpenItem], query: String, limit: Int) -> [QuickOpenItem] {
        let q = query.trimmingCharacters(in: .whitespaces)

        guard !q.isEmpty else {
            // Each alias is its own `.note` item (for query matching), so the
            // unfiltered browse list must dedup by the underlying note — otherwise
            // a note with N aliases appears N+1 times.
            var seen = Set<String>()
            let notes = items.filter { $0.kind == .note && seen.insert($0.note.fileURL.path).inserted }
            return Array(notes.prefix(limit))
        }

        let needle = FuzzyMatch.FoldedQuery(q)
        let scored = items.compactMap { item -> QuickOpenItem? in
            let haystack = item.subtitle.map { "\(item.title) \($0)" } ?? item.title
            guard let score = FuzzyMatch.score(needle, candidate: haystack) else { return nil }
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
            for (index, alias) in entry.aliases.enumerated() {
                items.append(QuickOpenItem(
                    // Indexed for the same reason the headings below are:
                    // `MarkdownParsing.aliases` preserves order and does not
                    // dedup, so front matter naming one alias twice produced two
                    // items sharing an id.
                    id: "\(entry.note.fileURL.path)|alias|\(index)|\(alias)",
                    note: entry.note,
                    kind: .note,
                    title: entry.note.title,
                    subtitle: "alias: \(alias)"
                ))
            }
            // The index is part of the id, not decoration: a note with two
            // `## Setup` sections — a README, a meeting-note template — produced
            // two items sharing one id, and `List(selection:)` cannot tell them
            // apart. SwiftUI logs a duplicate-id warning, the highlight can land
            // on the wrong row, and opening always resolved to the first of the
            // pair.
            for (index, heading) in entry.headings.enumerated() {
                items.append(QuickOpenItem(
                    id: "\(entry.note.fileURL.path)#\(index)#\(heading.title)",
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

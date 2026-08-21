//
//  LibrarySearch.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  Searching the library — one implementation, both shells.
//
//  It was written twice. `MacContentView.scheduleSearch` produced grouped
//  results with a snippet per hit and the attachments whose *contents* matched;
//  `iOSContentView.scheduleContentSearch` ran the identical two waves against
//  the identical Spotlight index and then threw both away, keeping a bare
//  `Set<URL>`. The consequence shipped: on iPad a phrase living only inside a
//  PDF was unfindable, and a note that matched showed no indication of why.
//
//  Making the second copy keep its snippets fixed that instance. It did not fix
//  the arrangement that produced it — two debounces, two cancellation policies,
//  two minimum query lengths, two merge rules, none of them tested, in two files
//  nobody diffs. So the search *decision* lives here, as an `@Observable` both
//  shells read, and what stays per-shell is the field's chrome and how each
//  draws a result row.
//
//  The two waves are the design, not an implementation detail:
//
//  1. **Titles and aliases**, straight from the metadata index — no file reads,
//     so results appear as fast as the user types.
//  2. **Contents**, via the system Spotlight index — which names the files whose
//     text matches, so only those are read (off-main) to verify and extract a
//     snippet. A query costs a handful of reads rather than a pass over the
//     vault, and attachments come back too, because Spotlight indexes a PDF's
//     text and we cannot.
//
//  Wave 2 replaces wave 1's rows for a collection rather than appending: a note
//  matched by both should appear once, with the snippet, which is the more
//  informative of the two answers.
//

import Foundation

@MainActor
@Observable
final class LibrarySearch {

    /// One collection's hits.
    struct Group: Identifiable {
        let collectionID: Collection.ID
        /// Matching notes, with the snippet that found them where there is one.
        let rows: [NoteRow]
        /// Attachments whose contents matched — PDFs, documents, anything
        /// Spotlight indexes and we do not.
        var files: [CollectionFile] = []
        var id: Collection.ID { collectionID }
    }

    private(set) var groups: [Group] = []
    /// Bumped whenever `groups` changes, for callers keying a cache on it.
    private(set) var revision = 0
    /// A second wave is on its way. Distinguishes "no matches" from "not yet",
    /// which is the difference between an empty state and a spinner.
    private(set) var isInFlight = false

    /// How long the typing has to stop before either wave runs.
    private static let debounce = Duration.milliseconds(200)

    /// Below this, a content search churns an enormous result set for no
    /// discriminating value. Title hits still stand.
    private static let minimumContentQuery = 3

    private var task: Task<Void, Never>?
    private var spotlight = SpotlightSearch()

    // MARK: - Reading the results

    func group(for id: Collection.ID) -> Group? { groups.first { $0.id == id } }

    /// The notes matching in `id`, in result order.
    func notes(in id: Collection.ID) -> [Note] { group(for: id)?.rows.map(\.note) ?? [] }

    /// The snippet a note matched by, if the content wave found one.
    func snippet(for url: URL) -> String? {
        for group in groups {
            if let row = group.rows.first(where: { $0.note.fileURL == url }) { return row.snippet }
        }
        return nil
    }

    var isEmpty: Bool { groups.allSatisfy { $0.rows.isEmpty && $0.files.isEmpty } }

    // MARK: - Running a search

    func clear() {
        task?.cancel()
        task = nil
        guard !groups.isEmpty || isInFlight else { return }
        groups = []
        isInFlight = false
        revision &+= 1
    }

    /// Search `collections` for `query`, publishing wave 1 immediately and wave
    /// 2 when it lands. Cancels whatever was in flight.
    func update(query raw: String, in collections: [Collection]) {
        task?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clear(); return }

        isInFlight = true
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled else { return }

            // Wave 1 — titles and aliases from the index. Instant.
            groups = collections.compactMap { collection in
                let rows = collection.search.titleResults(query: query)
                    .map { NoteRow(note: $0.note, snippet: nil) }
                return rows.isEmpty ? nil : Group(collectionID: collection.id, rows: rows)
            }
            revision &+= 1

            guard query.count >= Self.minimumContentQuery else {
                isInFlight = false
                return
            }

            // Wave 2 — contents, and the attachments Spotlight can read for us.
            let hits = await spotlight.search(query, in: collections.map(\.rootURL))
            guard !Task.isCancelled else { return }
            guard !hits.isEmpty else {
                // Finder semantics: no Spotlight hits means no content matches.
                // Wave 1's title hits still stand.
                isInFlight = false
                return
            }
            let hitPaths = Set(hits.map { $0.standardizedFileURL.path })

            var merged: [Group] = []
            for collection in collections {
                let candidates = collection.notes.map(\.fileURL)
                    .filter { hitPaths.contains($0.standardizedFileURL.path) }
                let contentHits = await collection.search.contentResults(query: query, in: candidates)
                guard !Task.isCancelled else { return }

                // A note matched by both waves appears once, carrying the
                // snippet — the more informative of the two answers.
                let contentURLs = Set(contentHits.map(\.id))
                let titleRows = (group(for: collection.id)?.rows ?? [])
                    .filter { !contentURLs.contains($0.note.fileURL) }
                let rows = contentHits.map { NoteRow(note: $0.note, snippet: $0.snippet) } + titleRows
                let files = collection.attachments.filter {
                    hitPaths.contains($0.url.standardizedFileURL.path)
                }
                guard !rows.isEmpty || !files.isEmpty else { continue }
                merged.append(Group(collectionID: collection.id, rows: rows, files: files))
            }
            guard !Task.isCancelled else { return }
            groups = merged
            revision &+= 1
            isInFlight = false
        }
    }
}

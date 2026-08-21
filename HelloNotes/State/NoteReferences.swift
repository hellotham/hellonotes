//
//  NoteReferences.swift
//  HelloNotes
//
//  Created by Chris Tham on 22/8/2026.
//
//  What points at this note, what it points at, and what mentions it without
//  linking — computed once, off the typing path.
//
//  All three were derived twice. The Mac computed them into a cached
//  `ReferencesData` keyed on the selection and the collection's revision, so a
//  keystroke cost nothing. The iPad computed the unlinked mentions the same way
//  — a near-identical `computeUnlinkedMentions`, down to the Spotlight
//  candidate pass — but built **backlinks and outgoing links inline in `body`**,
//  which is two O(notes) walks of the link graph per body evaluation, and the
//  inspector re-evaluates on every character typed.
//
//  That is the shape the plan calls Tier 3: O(notes) work in a view body, on
//  the typing path. It was invisible because the *feature* was present on both
//  — the inspector showed backlinks either way — and only the cost differed.
//

import Foundation

@MainActor
@Observable
final class NoteReferences {
    private(set) var backlinks: [Note] = []
    private(set) var outgoingLinks: [Note] = []
    private(set) var unlinkedMentions: [Note] = []

    /// Everything the answer depends on. Structural, not textual: typing does
    /// not change which notes link here, so typing must not recompute it.
    static func key(note: Note?, in collection: Collection?) -> String {
        "\(note?.fileURL.path ?? "")|\(collection?.derivedRevision ?? 0)"
    }

    /// The names a mention could use: the title, plus any aliases the index has
    /// cached — available immediately from the persistent cache, even before
    /// the note's text streams in.
    static func names(of note: Note, in collection: Collection) -> [String] {
        [note.title] + collection.search.aliases(of: note.fileURL)
    }

    func clear() {
        backlinks = []
        outgoingLinks = []
        unlinkedMentions = []
    }

    /// Recompute. Cancellable at every await, because the selection can move
    /// while a Spotlight query is in flight.
    func refresh(note: Note?, in collection: Collection?,
                 spotlight: SpotlightSearch) async {
        guard let note, let collection else { clear(); return }

        let back = collection.linkGraph.backlinks(for: note, in: collection.notes)
        let out = collection.linkGraph.outgoingLinks(for: note, in: collection.notes)
        backlinks = back
        outgoingLinks = out

        // A mention is a fact about the corpus the note lives in, so the search
        // is scoped to that collection's root — searching a different one comes
        // back empty.
        let names = Self.names(of: note, in: collection)
        let excluded = Set(back.map(\.fileURL)).union([note.fileURL])

        var candidatePaths: Set<String> = []
        for name in names {
            let hits = await spotlight.search(name, in: [collection.rootURL])
            guard !Task.isCancelled else { return }
            candidatePaths.formUnion(hits.map { $0.standardizedFileURL.path })
        }
        let candidates = collection.notes.filter {
            candidatePaths.contains($0.fileURL.standardizedFileURL.path)
                && !excluded.contains($0.fileURL)
        }

        let found = await offMain { () -> [Note] in
            candidates.compactMap { candidate in
                guard let text = try? FileIO.readString(at: candidate.fileURL),
                      MentionScanner.containsMention(of: names, in: text) else { return nil }
                return candidate
            }
        }
        guard !Task.isCancelled else { return }
        unlinkedMentions = found
    }
}

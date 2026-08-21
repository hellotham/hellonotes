//
//  WikiCompletions.swift
//  HelloNotes
//
//  What the `[[wiki-link]]` / `#tag` autocomplete offers, and how it ranks.
//
//  Cross-platform on purpose. The ranking used to live inside the macOS-only
//  `NoteEditorView`, which is why iPad had the detection (`EditorDocument`
//  reports the caret's inline context on both platforms) and the popup list,
//  but nothing in between. Two copies of a fuzzy ranker would have been the
//  worse fix: this is one, and both hosts call it.
//

import Foundation

/// The completion domains a host can be asked for.
enum EditorCompletionKind {
    case wikiLink
    case tag
}

/// The collection's side of autocomplete: what exists to link to, and how to
/// find the headings inside it. Closures rather than arrays for the headings,
/// because they are only ever needed for the one note the caret names.
struct WikiCompletionSource {
    /// Note titles and aliases — what `[[` can point at.
    var titles: [String] = []
    /// Every tag in the collection, `#` stripped.
    var tags: [String] = []
    /// Headings of a named note, for `[[Note#`.
    var headings: (String) -> [String] = { _ in [] }
    /// The note being edited, for the `[[#heading]]` self-reference form.
    var currentText: () -> String = { "" }

    /// At most 8 suggestions for `query`, best first.
    func matches(_ kind: EditorCompletionKind, query: String) -> [WikiCompletion] {
        switch kind {
        case .wikiLink:
            // `Note#Heading` — everything after the `#` ranks against that
            // note's headings, not against the vault's titles.
            if let hash = query.firstIndex(of: "#") {
                return headingMatches(notePart: String(query[..<hash]),
                                      query: String(query[query.index(after: hash)...]))
            }
            return noteMatches(query: query.trimmingCharacters(in: .whitespaces))
        case .tag:
            return tagMatches(partial: query)
        }
    }

    private func noteMatches(query: String) -> [WikiCompletion] {
        let ranked = rank(query, in: titles)
        // Nothing to offer if the only match is exactly what's already typed.
        if ranked.count == 1, ranked[0].localizedCaseInsensitiveCompare(query) == .orderedSame {
            return []
        }
        return ranked.map { WikiCompletion(label: $0, insert: $0, isHeading: false) }
    }

    private func headingMatches(notePart: String, query: String) -> [WikiCompletion] {
        let noteName = notePart.trimmingCharacters(in: .whitespaces)
        // Empty note part → headings of the note being edited (`[[#heading]]`).
        let candidates = noteName.isEmpty
            ? MarkdownParsing.headings(in: currentText()).map(\.title)
            : headings(noteName)
        return rank(query.trimmingCharacters(in: .whitespaces), in: candidates).map { heading in
            WikiCompletion(label: heading, insert: "\(noteName)#\(heading)", isHeading: true)
        }
    }

    private func tagMatches(partial: String) -> [WikiCompletion] {
        let ranked = rank(partial, in: tags)
        if ranked.count == 1, ranked[0].localizedCaseInsensitiveCompare(partial) == .orderedSame {
            return []
        }
        return ranked.map { WikiCompletion(label: "#\($0)", insert: $0, isHeading: false) }
    }

    /// An empty query offers the first few as-is; anything else is fuzzy-scored.
    private func rank(_ query: String, in candidates: [String]) -> [String] {
        guard !query.isEmpty else { return Array(candidates.prefix(8)) }
        return candidates
            .compactMap { c in FuzzyMatch.score(query: query, candidate: c).map { (c, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map(\.0)
    }
}

//
//  FuzzyMatch.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation

/// A tiny fuzzy subsequence matcher for "Open Quickly" style filtering.
///
/// `nonisolated` so it can be used from any actor. Pure and allocation-light.
nonisolated enum FuzzyMatch {

    private static let separators: Set<Character> = [" ", "/", "-", "_", ".", "\\"]

    /// The folding every user-facing text match in the app agrees on: case,
    /// diacritics and character width, the same three `localizedStandardContains`
    /// folds. `lowercased()` folded only case, and that is why `titleResults`
    /// could find `Café` from `cafe` while ⌘O and `[[wiki-link]]` completion —
    /// both of which come through here — could not. One matcher, one rule.
    ///
    /// `locale: nil`, deliberately, and for the reason `CloneRepositoryView`
    /// spells out beside its own copy of these options: `Locale.current` folding
    /// maps I↔ı on a Turkish device, so a query of `i` stops matching any
    /// candidate containing a capital `I`. This is the matcher behind ⌘O, the
    /// command palette and both completions — the widest blast radius in the
    /// app for that trap, and note titles are not a locale's business.
    private static func folded(_ text: String) -> [Character] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                           locale: nil))
    }

    /// Subsequence match, folding case, diacritics and width. Returns a score
    /// (higher is better), or `nil` if the characters of `query` don't appear,
    /// in order, within `candidate`. Consecutive matches and word-boundary
    /// matches score higher, so `"wl"` ranks `"wiki-links"` above an incidental
    /// scattering.
    static func score(query: String, candidate: String) -> Int? {
        score(FoldedQuery(query), candidate: candidate)
    }

    /// A query folded once, to be matched against many candidates.
    ///
    /// `score(query:candidate:)` folds *both* sides on every call, and every
    /// caller is a sweep over thousands of candidates with one fixed query — so
    /// the query was being re-folded once per candidate. On a large vault that
    /// is tens of thousands of redundant allocations per keystroke, on the main
    /// actor. Fold it once at the top of the sweep instead.
    struct FoldedQuery {
        let characters: [Character]
        let isEmpty: Bool
        init(_ query: String) {
            characters = folded(query)
            isEmpty = query.isEmpty
        }
    }

    static func score(_ query: FoldedQuery, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let needle = query.characters
        let haystack = folded(candidate)

        var n = 0
        var total = 0
        var lastMatchIndex = -1
        var prevWasSeparator = true

        for (index, character) in haystack.enumerated() {
            if n < needle.count, character == needle[n] {
                total += 1
                if lastMatchIndex >= 0, lastMatchIndex == index - 1 { total += 3 }   // consecutive run
                if prevWasSeparator { total += 5 }              // start of a word
                lastMatchIndex = index
                n += 1
            }
            prevWasSeparator = separators.contains(character)
        }

        return n == needle.count ? total : nil
    }
}

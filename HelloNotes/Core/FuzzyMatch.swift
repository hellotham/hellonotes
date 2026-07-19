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

    /// Case-insensitive subsequence match. Returns a score (higher is better),
    /// or `nil` if the characters of `query` don't appear, in order, within
    /// `candidate`. Consecutive matches and word-boundary matches score higher,
    /// so `"wl"` ranks `"wiki-links"` above an incidental scattering.
    static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())

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

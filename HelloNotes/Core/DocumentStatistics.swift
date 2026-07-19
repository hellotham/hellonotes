//
//  DocumentStatistics.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation

/// Word / character / paragraph counts and an estimated reading time for a note.
struct DocumentStatistics: Equatable, Sendable {
    var words: Int
    var characters: Int
    var paragraphs: Int
    var readingMinutes: Int

    static let empty = DocumentStatistics(words: 0, characters: 0, paragraphs: 0, readingMinutes: 0)
}

/// Pure, UI-agnostic document analysis. `nonisolated` so it runs on any actor.
nonisolated enum DocumentAnalyzer {
    /// Average adult reading speed used for the time estimate.
    private static let wordsPerMinute = 200

    static func analyze(_ text: String) -> DocumentStatistics {
        // Count only tokens with a letter or digit, so markdown markers
        // ("#", "-", "*", ">") aren't counted as words.
        let words = text
            .split { $0.isWhitespace || $0.isNewline }
            .filter { token in token.contains { $0.isLetter || $0.isNumber } }
            .count
        let characters = text.count
        // Normalise CRLF first: a Windows-authored note separates paragraphs
        // with "\r\n\r\n", which "\n\n" would never match (whole doc → 1 para).
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let minutes = words == 0 ? 0 : max(1, Int((Double(words) / Double(wordsPerMinute)).rounded(.up)))
        return DocumentStatistics(words: words, characters: characters, paragraphs: paragraphs, readingMinutes: minutes)
    }
}

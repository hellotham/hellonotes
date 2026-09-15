//
//  TokenBudget.swift
//  HelloNotes
//
//  Created by Chris Tham on 15/9/2026.
//
//  How much text fits in a model's context window — estimated, then split.
//
//  The old layer budgeted in *characters*, from a table keyed on provider name,
//  at roughly four characters to a token. That ratio is an English ratio. Asked
//  directly, the on-device model counts "The quick brown fox jumps over the lazy
//  dog." as 11 tokens — four characters each — and a 24-character Chinese
//  sentence as 19 tokens, nearly one per character. A character budget sized
//  for English sends a Chinese note five times over the window. With China back
//  in the App Store's territories that is not an edge case, so the estimate
//  here is script-aware, and every figure it is compared against comes from the
//  model (`LanguageModels.contextSize(of:)`) rather than from a table.
//
//  Estimates run high on purpose. Overestimating costs a slightly smaller chunk;
//  underestimating costs `contextSizeExceeded` halfway through a summary.
//

import Foundation

nonisolated enum TokenBudget {

    /// A deliberately generous token count for `text`.
    ///
    /// Three rates, by script: CJK ideographs, kana and Hangul at one token
    /// each; other non-Latin letters (Cyrillic, Arabic, Thai, Devanagari…) at
    /// two characters a token; everything else at 3.2 characters a token.
    static func estimate(_ text: String) -> Int {
        var dense = 0          // ~1 token per scalar
        var nonLatin = 0       // ~2 scalars per token
        var latin = 0          // ~3.2 scalars per token
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF,      // Hiragana, Katakana
                 0x3400...0x4DBF,      // CJK Extension A
                 0x4E00...0x9FFF,      // CJK Unified Ideographs
                 0xAC00...0xD7AF,      // Hangul syllables
                 0xF900...0xFAFF,      // CJK compatibility ideographs
                 0xFF00...0xFFEF,      // Half/full-width forms
                 0x1F000...0x1FAFF,    // Emoji — several tokens each, often
                 0x20000...0x2FA1F:    // CJK Extensions B–F
                dense += 1
            case 0x0000...0x024F:      // Basic Latin through Latin Extended-B
                latin += 1
            default:
                nonLatin += 1
            }
        }
        let tokens = Double(dense) + Double(nonLatin) / 2.0 + Double(latin) / 3.2
        return Int(tokens.rounded(.up))
    }

    /// Tokens left for input once instructions and the reply are paid for.
    ///
    /// The margin — a flat 64 tokens for the chat template, plus 5% of the
    /// window — covers what the estimate cannot see: role markers, a schema's
    /// JSON, the framework's own framing.
    static func inputTokens(context: Int, instructions: String, reply: Int) -> Int {
        let margin = 64 + context / 20
        return max(0, context - estimate(instructions) - reply - margin)
    }

    /// The longest leading part of `text` within `tokens`, cut at the most
    /// natural boundary available, and whether anything was cut.
    static func prefix(_ text: String, tokens: Int) -> (text: String, truncated: Bool) {
        let parts = chunks(text, tokens: tokens)
        return (parts.first ?? "", parts.count > 1)
    }

    /// `text` in order, split into pieces of at most `tokens` each.
    ///
    /// Splits at the largest boundary that works — paragraphs, then lines, then
    /// sentences (Latin and CJK), then words — and only cuts mid-run when a
    /// single unbroken run is longer than a whole chunk. Joining the result
    /// reproduces `text` exactly: nothing is trimmed, so a summary of the parts
    /// is a summary of the whole.
    static func chunks(_ text: String, tokens: Int) -> [String] {
        guard tokens > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }
        guard estimate(text) > tokens else { return [text] }
        return split(text, tokens: tokens, separators: ["\n\n", "\n", ". ", "。", "！", "？", " "][...])
    }

    private static func split(_ text: String, tokens: Int, separators: ArraySlice<String>) -> [String] {
        guard let separator = separators.first else { return hardSplit(text, tokens: tokens) }
        let pieces = text.components(separatedBy: separator)
        guard pieces.count > 1 else {
            return split(text, tokens: tokens, separators: separators.dropFirst())
        }

        var result: [String] = []
        var current = ""
        var currentTokens = 0
        for (index, piece) in pieces.enumerated() {
            let segment = index < pieces.count - 1 ? piece + separator : piece
            guard !segment.isEmpty else { continue }
            let segmentTokens = estimate(segment)
            if segmentTokens > tokens {
                if !current.isEmpty { result.append(current); current = ""; currentTokens = 0 }
                result += split(segment, tokens: tokens, separators: separators.dropFirst())
            } else if currentTokens + segmentTokens > tokens, !current.isEmpty {
                result.append(current)
                current = segment
                currentTokens = segmentTokens
            } else {
                current += segment
                currentTokens += segmentTokens
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The last resort: an unbroken run longer than a chunk, cut by length.
    private static func hardSplit(_ text: String, tokens: Int) -> [String] {
        let ratio = Double(text.count) / Double(max(estimate(text), 1))
        let size = max(1, Int(Double(tokens) * ratio))
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}

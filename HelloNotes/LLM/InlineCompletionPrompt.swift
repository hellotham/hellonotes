//
//  InlineCompletionPrompt.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  The ghost-text prompt, written once for both provider paths.
//
//  Harder to word than it looks, because the failure modes are not "a wrong
//  answer" — they are answers that are *correct as chat* and useless as ghost
//  text. A model asked to continue a sentence will happily reply "Sure! Here's
//  a continuation:", or repeat the words it was given before adding to them, or
//  write three paragraphs. Every one of those renders as nonsense next to the
//  caret, and the last one is silently truncated to a line that means something
//  different. So the instruction is mostly a list of things not to say, and the
//  reply is normalised again on arrival (`InlineSuggestion.sanitise`) rather
//  than trusted.
//

import Foundation

nonisolated enum InlineCompletionPrompt {

    static let instructions = """
    You continue the sentence someone is typing in their Markdown notes.

    Reply with ONLY the characters that come next — the continuation itself. \
    Never repeat any of the text you were given. Never add a preamble, an \
    explanation, quotation marks, or a code fence. Keep it to at most one short \
    sentence, on a single line.

    Match the author's voice, tense and Markdown style. If the text ends \
    mid-word, finish that word. If the text already reads as complete, or you \
    would only be guessing, reply with nothing at all — an empty reply is a \
    good answer and is far better than a plausible invention.
    """

    /// The turn: what comes before the caret, and what already follows it.
    ///
    /// The suffix is included so the completion does not write the sentence
    /// that is already on the next line — the single most common way ghost
    /// text in a *note* (as opposed to in code) turns into an obvious duplicate.
    static func user(prefix: String, suffix: String) -> String {
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSuffix.isEmpty else {
            return "Continue from the end of this text:\n\n\(prefix)"
        }
        return """
        Continue from the end of this text:

        \(prefix)

        For context only — this already follows, so do not duplicate it:

        \(trimmedSuffix)
        """
    }
}

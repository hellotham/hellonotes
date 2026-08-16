//
//  ComposePrompt.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  The one place the compose instructions are written.
//
//  Two providers run this feature — the on-device model through
//  `NoteIntelligence` and everything else through `IntelligenceService` — and
//  the wording is not cosmetic: it is what decides whether the reply arrives as
//  a note or as a chat answer *about* a note, and whether the vault links it
//  offers are shaped like links at all. Two copies would drift, and the drift
//  would show up as one provider quietly producing worse notes than the other.
//

import Foundation

nonisolated enum ComposePrompt {

    static let instructions = """
    You write notes for someone's personal Markdown notebook. Reply with the \
    note itself and nothing else — no preamble, no "here is", no surrounding \
    code fence. Open with a single `# Title` line, then the body in clear \
    Markdown using headings and lists where they help.

    Write in the second person's own voice: this is a note in their notebook, \
    not a letter to them. If the request cannot be answered from what you know, \
    say so in the note rather than inventing specifics.
    """

    /// The user turn: what to write, and which of their notes it may link to.
    ///
    /// The titles are *offered*, not imposed. A model told to link things will
    /// link things, so the instruction says "where you genuinely refer to one",
    /// and — more importantly — every link it returns is checked against the
    /// collection afterwards (`ComposedNote.resolveWikiLinks`). The prompt is
    /// the polite request; the verification is the guarantee.
    static func user(prompt: String, titles: [String], budget: Int) -> String {
        guard !titles.isEmpty else { return prompt }

        // Spend at most half the budget on titles: the request is the point,
        // and a long title list must never be what pushes it out of the window.
        var offered: [String] = []
        var used = 0
        for title in titles {
            guard used + title.count + 1 <= budget / 2 else { break }
            offered.append(title)
            used += title.count + 1
        }
        guard !offered.isEmpty else { return prompt }

        return """
        \(prompt)

        Notes that already exist in this notebook:
        \(offered.joined(separator: "\n"))

        Where the note genuinely refers to one of those, link it as \
        [[Exact Title]], copying the title exactly as written above. Do not \
        link to anything not on that list, and do not force a link in where it \
        does not belong.
        """
    }
}

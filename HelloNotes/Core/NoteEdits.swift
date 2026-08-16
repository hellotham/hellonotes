//
//  NoteEdits.swift
//  HelloNotes
//
//  Applying an accepted suggestion to a note's text.
//
//  Each of these is what happens when someone presses a chip in the inspector:
//  a tag, a link, a summary. They are pure string transforms, and they live here
//  rather than in the view that offers them for two reasons. They are shared —
//  the inspector offers them, the menu bar and the palette route to the same
//  thing, and iOS will need them unchanged. And they carry invariants worth
//  proving rather than asserting: accepting four link suggestions one at a time
//  must produce one `## Related` section, not four, which is exactly the kind of
//  claim a comment makes confidently and wrongly.
//

import Foundation

enum NoteEdits {
    /// The note with `tag` appended as a plain `#tag`.
    ///
    /// Plain body text rather than front matter, because a note's own tags are
    /// parsed from its body (`MarkdownParsing.tags`) — that is where a tag has
    /// to be for the rail to show it back. Joins the last line when that line is
    /// already nothing but tags, so accepting three suggestions gives one tag
    /// line rather than three.
    static func addingTag(_ tag: String, to text: String) -> String {
        let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let isTagLine = !lastLine.isEmpty && lastLine.split(separator: " ").allSatisfy {
            $0.hasPrefix("#") && $0.count > 1
        }
        if isTagLine { return text + " #\(tag)" }
        let separator = text.isEmpty ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + "#\(tag)"
    }

    /// A wiki link to `target` that reads as `phrase` where it stands.
    ///
    /// `[[Target]]` when the phrase *is* the title, `[[Target|phrase]]`
    /// otherwise — so linking the words "second brains" to a note called
    /// **Second Brain** leaves the sentence reading the way it was written.
    /// Case is part of that: the display text keeps whatever the author typed.
    static func wikiLink(to target: String, shownAs phrase: String) -> String {
        phrase == target ? "[[\(target)]]" : "[[\(target)|\(phrase)]]"
    }

    /// The note with `[[title]]` added under a `## Related` heading — the
    /// existing one when the note already has it.
    static func addingRelatedLink(_ title: String, to text: String) -> String {
        let line = "- [[\(title)]]"
        var lines = text.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: isRelatedHeading) else {
            return text.trimmingTrailingNewlines() + "\n\n## Related\n\(line)\n"
        }
        // The section runs to the next heading, or to the end of the note …
        var end = heading + 1
        while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
        // … but not into the blank lines separating it from what follows, or
        // each accepted link pushes the gap one line wider.
        while end > heading + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        lines.insert(line, at: end)
        return lines.joined(separator: "\n")
    }

    /// Whether `line` is the note's Related heading.
    ///
    /// Deliberately loose about the two things Markdown is loose about — the
    /// number of `#`s and the space after them. A note carrying `##  Related`
    /// or `# Related` holds the same section as far as a reader is concerned,
    /// and a matcher that insisted on `"## Related"` exactly would answer "no
    /// such section" and write a second one, which is the single failure this
    /// function exists to prevent.
    private static func isRelatedHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return false }
        let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        return text.caseInsensitiveCompare("Related") == .orderedSame
    }

    /// The note with `summary` inserted as a `> [!summary]` callout at the top
    /// of the body — after any front matter, which is both where a reader looks
    /// for one and the only position that doesn't corrupt the YAML.
    static func insertingSummaryCallout(_ summary: String, into text: String) -> String {
        let quoted = summary
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        let callout = "> [!summary] Summary\n\(quoted)\n\n"

        let body = FrontMatter.body(of: text)
        guard body.count < text.count else { return callout + text }
        return String(text.dropLast(body.count)) + callout + body
    }
}

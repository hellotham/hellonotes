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

nonisolated enum NoteEdits {
    /// The note with `tag` appended as a plain `#tag`.
    ///
    /// Plain body text rather than front matter, because a note's own tags are
    /// parsed from its body (`MarkdownParsing.tags`) — that is where a tag has
    /// to be for the rail to show it back. Joins the last line when that line is
    /// already nothing but tags, so accepting three suggestions gives one tag
    /// line rather than three.
    static func addingTag(_ tag: String, to text: String) -> String {
        appending(tag, toListProperty: "tags", of: text)
    }

    /// Add `value` to a front-matter list property, creating the property — and
    /// the front-matter block — if neither exists.
    ///
    /// **Metadata belongs in metadata.** Every accepted suggestion used to be
    /// written into the *body*: a tag appended after the last paragraph, a link
    /// under a `## Related` heading the app invented, a summary as a callout
    /// pushed above the first line. That is the app editing prose the user
    /// wrote, to record something that was never prose — and it is not
    /// reversible by any means the app offers. A property can be removed in the
    /// Properties pane; a paragraph the app inserted has to be found and
    /// deleted by hand.
    ///
    /// It also travels: `tags:` is how Obsidian declares tags, so a note tagged
    /// here reads as tagged there.
    static func appending(_ value: String, toListProperty key: String, of text: String) -> String {
        var properties = FrontMatter.properties(in: text)
        let index = properties.firstIndex { $0.key.caseInsensitiveCompare(key) == .orderedSame }

        guard let index else {
            properties.append(Property(key: key, kind: .list, text: "",
                                       bool: false, items: [value]))
            return FrontMatter.applying(properties, to: text)
        }

        // A key written as a scalar (`tags: research`) becomes a list rather
        // than being overwritten — the existing value is the user's.
        var items = properties[index].kind == .list
            ? properties[index].items
            : properties[index].text.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

        guard !items.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            return text
        }
        items.append(value)
        properties[index].kind = .list
        properties[index].items = items
        properties[index].text = ""
        return FrontMatter.applying(properties, to: text)
    }

    /// Set a single-valued front-matter property, replacing any current value.
    static func setting(_ value: String, property key: String, of text: String) -> String {
        // YAML scalars are one line. A summary is two to four sentences, so
        // folding newlines to spaces loses nothing a reader wants and keeps the
        // block parseable by everything that reads it.
        let flattened = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var properties = FrontMatter.properties(in: text)
        if let index = properties.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            properties[index].kind = .text
            properties[index].text = flattened
            properties[index].items = []
        } else {
            properties.append(Property(key: key, kind: .text, text: flattened,
                                       bool: false, items: []))
        }
        return FrontMatter.applying(properties, to: text)
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
    /// The note with `[[title]]` recorded in its `related:` property.
    ///
    /// It used to append `- [[title]]` under a `## Related` heading, inventing
    /// that heading at the end of the note if it was absent — the app writing a
    /// section into someone's prose to store a relationship. As a property it is
    /// visible in the Properties pane, removable there, and still a real link:
    /// `wikiLinkTargets` scans the whole document, so backlinks and the graph
    /// see it exactly as they saw the body version.
    static func addingRelatedLink(_ title: String, to text: String) -> String {
        appending("[[\(title)]]", toListProperty: "related", of: text)
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
    /// The note with `summary` recorded in its `summary:` property.
    ///
    /// It used to push a `> [!summary]` callout above the note's first line —
    /// the most intrusive of the three, since it displaced the opening of
    /// whatever the author had written. A generated description is metadata
    /// about the note, not part of it.
    static func settingSummary(_ summary: String, in text: String) -> String {
        setting(summary, property: "summary", of: text)
    }
}

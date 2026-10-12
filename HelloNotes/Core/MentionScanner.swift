//
//  MentionScanner.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation

/// Finds "unlinked mentions" — a note's title/aliases appearing as plain text
/// in another note but **not** already wrapped in a `[[wiki-link]]` (Core layer).
nonisolated enum MentionScanner {

    /// Does `text` contain any of `names` as a word-boundaried plain-text
    /// mention that isn't already the start of a `[[wiki-link]]`?
    static func containsMention(of names: [String], in text: String) -> Bool {
        let ns = text as NSString
        for name in names where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            // Fast reject: a word-boundary regex over the whole note is
            // expensive, so skip it entirely unless the substring is present
            // at all. Most notes don't mention most other notes, so this
            // avoids the vast majority of regex scans in a large collection.
            guard text.range(of: name, options: .caseInsensitive) != nil else { continue }
            guard let regex = wordRegex(for: name) else { continue }
            let found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in found where !isInsideWikiLink(match.range, in: ns) {
                return true
            }
        }
        return false
    }

    /// Link the first bare mention of the note called `title` in `text`,
    /// returning the rewritten text — or nil if there is no bare mention to
    /// link.
    ///
    /// `names` are everything the note answers to — its title and its aliases,
    /// the names the Links view found the mention by (`NoteReferences.names`).
    /// A mention by the title becomes `[[as written]]`, as it always did; one
    /// by an alias becomes `[[Title|as written]]`, so the sentence reads as it
    /// did and the link says where it goes. The scanner was given the title
    /// alone, so for a note listed because of an alias the Link button
    /// changed nothing (implemented.md §51.44).
    ///
    /// The first is the earliest in the text, whichever name it uses; of two
    /// that start at the same place, the longer.
    static func linkingFirstMention(of names: [String], to title: String, in text: String) -> String? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var first: NSRange?
        for name in names where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            // The same fast reject as `containsMention`: no substring, no regex.
            guard ns.range(of: name, options: .caseInsensitive).location != NSNotFound,
                  let regex = wordRegex(for: name),
                  let range = regex.matches(in: text, range: whole)
                    .first(where: { !isInsideWikiLink($0.range, in: ns) })?.range
            else { continue }
            if let found = first, (found.location, -found.length) <= (range.location, -range.length) { continue }
            first = range
        }
        guard let first else { return nil }
        let matched = ns.substring(with: first)
        let link = matched.caseInsensitiveCompare(title) == .orderedSame
            ? "[[\(matched)]]" : "[[\(title)|\(matched)]]"
        return ns.replacingCharacters(in: first, with: link)
    }

    /// The same for a note with one name.
    static func linkingFirstMention(of name: String, in text: String) -> String? {
        linkingFirstMention(of: [name], to: name, in: text)
    }

    // MARK: - Private

    /// Compiled word-boundary matchers, cached by name — building an
    /// `NSRegularExpression` is costly and the same names are scanned against
    /// thousands of notes. `NSCache` is thread-safe, matching `nonisolated` —
    /// Foundation documents it so, and it locks internally — which the compiler
    /// cannot see in a type that is not `Sendable`: hence `nonisolated(unsafe)`,
    /// rather than a second lock around a lock.
    nonisolated(unsafe) private static let regexCache = NSCache<NSString, NSRegularExpression>()

    /// A case-insensitive, word-boundaried matcher for a literal name (cached).
    private static func wordRegex(for name: String) -> NSRegularExpression? {
        if let cached = regexCache.object(forKey: name as NSString) { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}0-9_])\(escaped)(?![\\p{L}0-9_])",
            options: [.caseInsensitive]
        ) else { return nil }
        regexCache.setObject(regex, forKey: name as NSString)
        return regex
    }

    /// True when the match falls inside an existing `[[wiki-link]]` — not only
    /// when it's immediately preceded by `[[`, but also when it's embedded in a
    /// multi-word target or alias (`[[My Note]]`, `[[Foo|Bar]]`, `[[Note#h]]`).
    /// Checking only the two preceding characters would let `linkingFirstMention`
    /// rewrite `Note` inside `[[My Note]]` into `[[My [[Note]]]]`, corrupting the
    /// file. We're inside a link when the nearest `[[` before the match, **on
    /// its line**, has no closing `]]` between it and the match.
    ///
    /// Searched in place, within the line. It copied everything before the
    /// match to search it — once per match, so a megabyte note with a few
    /// hundred links took 160 ms on the main actor for one name — and looked
    /// back past the line, so a stray `[[` anywhere above made every mention
    /// below it "inside a link". A link does not span lines
    /// (`EditorDocument.inlineContext`).
    private static func isInsideWikiLink(_ range: NSRange, in ns: NSString) -> Bool {
        let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
        guard range.location - lineStart >= 2 else { return false }
        let before = NSRange(location: lineStart, length: range.location - lineStart)
        let open = ns.range(of: "[[", options: .backwards, range: before)
        guard open.location != NSNotFound else { return false }
        let between = NSRange(location: open.location + 2, length: range.location - (open.location + 2))
        return ns.range(of: "]]", options: [], range: between).location == NSNotFound
    }
}

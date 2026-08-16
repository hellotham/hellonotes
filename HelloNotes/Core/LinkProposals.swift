//
//  LinkProposals.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  "You wrote the words *Second Brain* here, and you have a note called that.
//   Link it?"
//
//  ## Why the exact scan comes first
//
//  `docs/semantic-retrieval-benchmark.md` measured it: of the 520 author-made
//  links in the vault, **40% have the target's title present verbatim in the
//  source note**. Those need no model, no index and no judgement call — they are
//  found by scanning, they are exact, and they are the highest-precision link
//  proposals available. Retrieval and the model earn their keep on the other
//  60%, which arrive as note-level suggestions in the References tab rather than
//  as inline phrase links, because retrieval identifies a *note* and has no
//  opinion about which words in this note should carry the link.
//
//  ## Precision over recall, stated as rules
//
//  A wrong link corrupts the graph the Researcher persona depends on, and does
//  it *silently* — nobody re-reads a link they accepted. Five confident links
//  beat fifty speculative ones, so:
//
//  - **First occurrence only.** Linking every instance of a word is what makes
//    auto-linked vaults unreadable.
//  - **Never inside markup.** Code, math, front matter, headings, URLs and
//    existing links are all places where inserting `[[…]]` is somewhere between
//    meaningless and destructive — a link inside a fenced code block changes
//    what the code *says*.
//  - **Never twice.** If the note already links to that target anywhere, there
//    is nothing to propose.
//  - **"Never" is remembered**, per collection, or the same rejected proposal
//    returns every time and the feature becomes noise.
//

import Foundation

/// One proposed link: a phrase in this note, and the note it should point at.
struct LinkProposal: Identifiable, Equatable, Sendable {
    /// Stable across regeneration of the same note, so a review session can
    /// track what has been decided.
    var id: String { "\(targetTitle.lowercased())@\(range.location)" }
    let range: NSRange
    /// The matched text exactly as the author wrote it — casing included, since
    /// the replacement has to preserve the sentence.
    let phrase: String
    let targetTitle: String
    let targetURL: URL
}

/// A note that could be linked to.
struct LinkCandidate: Sendable {
    let title: String
    let url: URL
    /// Front-matter aliases, which are equally valid ways to name the note.
    var aliases: [String] = []

    /// Every name this note answers to.
    var names: [String] { [title] + aliases }
}

nonisolated enum LinkProposals {

    /// Proposals for `text`, best-positioned first.
    ///
    /// - Parameter declined: proposal keys the user has said "never" to
    ///   (`declineKey(phrase:target:)`).
    static func proposals(in text: String,
                          candidates: [LinkCandidate],
                          declined: Set<String> = [],
                          excludingNoteAt selfURL: URL? = nil) -> [LinkProposal] {
        guard !text.isEmpty, !candidates.isEmpty else { return [] }
        let ns = text as NSString
        let zones = ExclusionZones.ranges(in: text)
        // Targets this note already links to are settled business.
        let alreadyLinked = Set(MarkdownParsing.wikiLinkTargets(in: text).map { $0.lowercased() })

        var found: [LinkProposal] = []
        for candidate in candidates {
            guard candidate.url != selfURL else { continue }
            guard !alreadyLinked.contains(candidate.title.lowercased()) else { continue }

            // The earliest acceptable occurrence of *any* of this note's names.
            var best: (range: NSRange, phrase: String)?
            for name in candidate.names {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                // One- and two-character names match everywhere and mean
                // nothing; a note called "A" must not link every indefinite
                // article in the vault.
                guard trimmed.count >= 3 else { continue }
                // Fast reject before the word-boundary regex — most notes
                // mention most other notes never.
                guard text.range(of: trimmed, options: .caseInsensitive) != nil else { continue }
                guard let regex = Self.wordRegex(for: trimmed) else { continue }

                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    guard !zones.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                    else { continue }
                    if best == nil || match.range.location < best!.range.location {
                        best = (match.range, ns.substring(with: match.range))
                    }
                    break   // first occurrence of this name is enough
                }
            }

            guard let best else { continue }
            let proposal = LinkProposal(range: best.range, phrase: best.phrase,
                                        targetTitle: candidate.title, targetURL: candidate.url)
            guard !declined.contains(declineKey(phrase: best.phrase, target: candidate.title))
            else { continue }
            found.append(proposal)
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Apply `proposals` to `text`, rewriting each phrase as a wiki link.
    ///
    /// Applied **back to front** so that every range stays valid: inserting
    /// `[[` `]]` at an earlier offset shifts everything after it, and applying
    /// forwards silently corrupts the note from the second link onward.
    static func apply(_ proposals: [LinkProposal], to text: String) -> String {
        var result = text as NSString
        for proposal in proposals.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(proposal.range) <= result.length else { continue }
            let replacement = NoteEdits.wikiLink(to: proposal.targetTitle, shownAs: proposal.phrase)
            result = result.replacingCharacters(in: proposal.range, with: replacement) as NSString
        }
        return result as String
    }

    /// The key a "never" decision is stored under.
    ///
    /// Keyed on the *phrase and target*, not on the position: the same words in
    /// a different paragraph deserve the same answer, but a different phrase
    /// pointing at the same note is a fresh question.
    static func declineKey(phrase: String, target: String) -> String {
        "\(phrase.lowercased())→\(target.lowercased())"
    }

    // MARK: - Private

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func wordRegex(for name: String) -> NSRegularExpression? {
        if let cached = regexCache.object(forKey: name as NSString) { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}0-9_])\(escaped)(?![\\p{L}0-9_])",
            options: [.caseInsensitive]) else { return nil }
        regexCache.setObject(regex, forKey: name as NSString)
        return regex
    }
}

// MARK: - Where a link must never go

/// The spans of a Markdown note that are markup rather than prose.
///
/// The editor already knows this for the *open* document
/// (`EditorDocument.isSourceOnly`), but that needs a parsed document and a live
/// editor. Proposals are generated for notes that are merely on disk — during a
/// collection-wide pass, none of them are open — so the same question has to be
/// answerable from raw text.
nonisolated enum ExclusionZones {

    static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var zones: [NSRange] = []

        for pattern in patterns {
            zones += pattern.matches(in: text, range: whole).map(\.range)
        }
        zones += indentedCodeRanges(in: text)
        return zones
    }

    /// Compiled once. Order does not matter — every match is excluded.
    private static let patterns: [NSRegularExpression] = [
        // Front matter, but only at the very start of the file.
        try! NSRegularExpression(pattern: #"\A---\r?\n.*?\r?\n---"#,
                                 options: [.dotMatchesLineSeparators]),
        // Fenced code. Non-greedy, so two separate fences do not merge into one
        // zone that swallows the prose between them.
        try! NSRegularExpression(pattern: "```[\\s\\S]*?```"),
        try! NSRegularExpression(pattern: "~~~[\\s\\S]*?~~~"),
        // Display and inline math.
        try! NSRegularExpression(pattern: #"\$\$[\s\S]*?\$\$"#),
        try! NSRegularExpression(pattern: #"(?<!\$)\$[^\$\r\n]+\$(?!\$)"#),
        // Inline code.
        try! NSRegularExpression(pattern: "`[^`\r\n]+`"),
        // Headings — a link in a heading breaks the outline and the anchor.
        try! NSRegularExpression(pattern: #"(?m)^[ \t]{0,3}#{1,6}[ \t].*$"#),
        // Existing links, whole: `[[target|display]]`, `[text](url)`, and bare
        // URLs. The *display text* is excluded too, deliberately — nesting a
        // link inside a link produces markup that renders as neither.
        try! NSRegularExpression(pattern: #"!?\[\[[^\]\r\n]*\]\]"#),
        try! NSRegularExpression(pattern: #"!?\[[^\]\r\n]*\]\([^)\r\n]*\)"#),
        try! NSRegularExpression(pattern: #"https?://\S+"#),
        // Tags: `#second-brain` is already a navigational token.
        try! NSRegularExpression(pattern: #"(?<![\p{L}0-9_])#[\p{L}0-9_/-]+"#),
    ]

    /// Indented code blocks — four spaces or a tab at the start of a line.
    ///
    /// Not a regex, because "indented" only means code when the line is not
    /// part of a list item's continuation, and distinguishing those needs the
    /// preceding line. A regex that ignores that turns every wrapped bullet
    /// into an exclusion zone and silently suppresses proposals across whole
    /// notes.
    private static func indentedCodeRanges(in text: String) -> [NSRange] {
        var zones: [NSRange] = []
        var location = 0
        var previousWasBlankOrCode = true
        let ns = text as NSString

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = ns.substring(with: lineRange)
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let isIndented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if isIndented && previousWasBlankOrCode {
                zones.append(lineRange)
                previousWasBlankOrCode = true
            } else {
                previousWasBlankOrCode = isBlank
            }
            location = NSMaxRange(lineRange)
        }
        _ = location
        return zones
    }
}

//
//  ComposedNote.swift
//  HelloNotes
//
//  Created by Chris Tham on 16/8/2026.
//
//  Turning a model's reply into a note that belongs in the vault.
//
//  A reply is not a note. It arrives wrapped in code fences, titled by a
//  heading that would then be duplicated by the filename, citing sources inline
//  with nothing gathering them, and — when the model has been told which notes
//  exist — carrying `[[wiki-links]]`, some of which name notes that do not.
//
//  That last one is the reason this file is pure and separately tested. A
//  research note is the one kind of note nobody proofreads: it is generated,
//  skimmed, and filed. An invented `[[link]]` inside it does not look wrong — it
//  looks exactly like a real link, and it silently creates a note-shaped hole
//  that the graph, the backlinks panel and the Researcher persona all take at
//  face value. So a wiki-link survives only if a note with that title actually
//  exists; everything else is unwrapped back to plain text and *reported*, not
//  quietly dropped. The model may propose a connection. It may not assert one.
//

import Foundation

/// A note the app has composed but has not written.
///
/// Deliberately a value, produced by pure functions and shown to the user
/// before anything reaches the disk: composition is the step where a model's
/// confidence is highest and its accountability lowest.
struct NoteDraft: Equatable, Sendable {
    /// Also the filename, so it is already sanitised.
    var title: String
    var body: String
    /// Web sources cited in the body, in order of first appearance.
    var sources: [URL] = []
    /// Vault notes the draft links to. Every one verified to exist.
    var linkedTitles: [String] = []
    /// Wiki-links the model asked for that name no note in the collection.
    /// Unwrapped to plain text, and kept here so the UI can say so — a link the
    /// app declined to make is worth one line of explanation, because the
    /// alternative reads as the model having simply not bothered.
    var droppedLinks: [String] = []

    var markdown: String {
        body.hasSuffix("\n") ? body : body + "\n"
    }
}

nonisolated enum ComposedNote {

    /// A plain composed note: the model wrote prose, we give it a title and a
    /// filename.
    static func draft(from reply: String, prompt: String, knownTitles: [String] = []) -> NoteDraft {
        let unfenced = unwrappingWholeDocumentFence(reply)
        let (title, body) = splitLeadingTitle(from: unfenced)
        let resolved = resolveWikiLinks(in: body, knownTitles: knownTitles)

        return NoteDraft(
            title: filename(title ?? summarised(prompt)),
            body: resolved.text.trimmingCharacters(in: .whitespacesAndNewlines),
            sources: sources(in: resolved.text),
            linkedTitles: resolved.kept,
            droppedLinks: resolved.dropped)
    }

    /// A research note: the same, plus provenance and a gathered source list.
    ///
    /// `date` is passed rather than read so this stays a function of its
    /// arguments — a formatter reading the clock is the standard way a pure
    /// transform acquires a test that fails once a day.
    static func researchDraft(question: String,
                              synthesis: String,
                              knownTitles: [String] = [],
                              date: Date) -> NoteDraft {
        var draft = self.draft(from: synthesis, prompt: question, knownTitles: knownTitles)
        var body = draft.body

        if !draft.sources.isEmpty, !hasSourceSection(body) {
            body += "\n\n## Sources\n\n"
                + draft.sources.map { "- <\($0.absoluteString)>" }.joined(separator: "\n")
        }
        draft.body = frontMatter(question: question, date: date) + "\n" + body
        return draft
    }

    // MARK: - Front matter

    /// Provenance for a note nobody wrote.
    ///
    /// Worth the intrusion of a YAML block precisely because a synthesised note
    /// is indistinguishable from a written one six months later, and the
    /// difference decides how much you should trust it. Shown in the draft, so
    /// anyone who disagrees can delete it before it is created.
    private static func frontMatter(question: String, date: Date) -> String {
        var formatter = Date.ISO8601FormatStyle(timeZone: .current)
        formatter = formatter.year().month().day()
        return """
        ---
        created: \(date.formatted(formatter))
        source: research
        question: \(yamlScalar(question))
        ---

        """
    }

    /// A YAML double-quoted scalar, which is the only form that survives a
    /// question containing `:`, `#` or a quote — and questions contain all
    /// three often enough that a bare scalar corrupts the front matter of a
    /// note the user never inspects.
    static func yamlScalar(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    // MARK: - Wiki-links

    struct ResolvedLinks: Equatable {
        var text: String
        var kept: [String] = []
        var dropped: [String] = []
    }

    private static let wikiLink = try! NSRegularExpression(
        pattern: #"(?<!!)\[\[([^\|\]\r\n]*)(?:\|([^\]\r\n]+))?\]\]"#)

    /// Keep every `[[link]]` that names a real note; unwrap the rest to plain
    /// text.
    ///
    /// A kept link is rewritten to the note's **canonical** title so it matches
    /// the file, and an unwrapped one keeps its display text so the sentence
    /// still reads. Embeds (`![[…]]`) are left alone: they are a different
    /// feature, and one that fails visibly rather than silently.
    static func resolveWikiLinks(in text: String, knownTitles: [String]) -> ResolvedLinks {
        let ns = text as NSString
        guard ns.length > 0 else { return ResolvedLinks(text: text) }

        let canonical = Dictionary(
            knownTitles.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        // `[[…]]` inside a code fence is sample text, not a link. It must be
        // neither validated nor unwrapped — rewriting it would edit the example.
        let verbatim = ExclusionZones.verbatimRanges(in: text)

        var result = text
        var kept: [String] = []
        var dropped: [String] = []

        // Back to front, so each replacement leaves earlier ranges valid.
        let matches = wikiLink.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard !verbatim.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { continue }

            let target = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            let alias = match.range(at: 2).location == NSNotFound
                ? nil : ns.substring(with: match.range(at: 2))

            if let real = canonical[target.lowercased()] {
                kept.append(real)
                let replacement = alias.map { "[[\(real)|\($0)]]" } ?? "[[\(real)]]"
                result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            } else {
                dropped.append(target)
                result = (result as NSString)
                    .replacingCharacters(in: match.range, with: alias ?? target)
            }
        }
        // Reversed iteration collected these back to front; report in reading order.
        return ResolvedLinks(text: result,
                             kept: distinct(kept.reversed()),
                             dropped: distinct(dropped.reversed()))
    }

    // MARK: - Sources

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"']+"#)

    /// Distinct http(s) URLs in the body, in order of first appearance.
    static func sources(in text: String) -> [URL] {
        let ns = text as NSString
        let verbatim = ExclusionZones.verbatimRanges(in: text)
        var seen = Set<String>()
        var found: [URL] = []

        for match in urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard !verbatim.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { continue }
            // Trailing punctuation belongs to the sentence, not the URL —
            // "see https://example.com/a." must not cite `…/a.`.
            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
            guard seen.insert(raw).inserted, let url = URL(string: raw) else { continue }
            found.append(url)
        }
        return found
    }

    private static func hasSourceSection(_ body: String) -> Bool {
        let names = ["sources", "references", "citations", "further reading"]
        return body.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return false }
            let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
            return names.contains(text)
        }
    }

    // MARK: - Title and body

    /// Pull a leading `# Heading` off the reply and use it as the title.
    ///
    /// Left in place it would be a second title: the filename already names the
    /// note, and the editor shows that name above the text.
    static func splitLeadingTitle(from text: String) -> (title: String?, body: String) {
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.count else { return (nil, text) }

        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
        guard candidate.hasPrefix("# ") else { return (nil, text) }

        let title = String(candidate.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return (nil, text) }

        lines.removeSubrange(0...index)
        return (title, lines.joined(separator: "\n"))
    }

    /// A title for a note whose reply gave none: the prompt, shortened at a
    /// word boundary so it reads as a name rather than a truncation.
    static func summarised(_ prompt: String) -> String {
        let flat = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "Untitled" }
        guard flat.count > 60 else { return stripTrailingPunctuation(flat) }

        var clipped = String(flat.prefix(60))
        if let space = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: space) > 20 {
            clipped = String(clipped[..<space])
        }
        return stripTrailingPunctuation(clipped)
    }

    private static func stripTrailingPunctuation(_ text: String) -> String {
        var out = text
        while let last = out.last, ".,;:!?…".contains(last) { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A title safe to use as a filename.
    ///
    /// `/` and `:` are the two that matter on macOS — `/` because
    /// `appendingPathComponent` would quietly create a subdirectory, and `:`
    /// because the Finder still renders it as `/`. Matches `renameNote`.
    ///
    /// A leading dot is stripped as well, and that one is not cosmetic: the
    /// collection scanner skips dotfiles, so a note titled `.env` — or
    /// `../Escaped`, which sanitising the slash turns into `..-Escaped` — is
    /// written to disk successfully and then never appears. The file exists,
    /// the note does not, and nothing reports a failure.
    static func filename(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "." }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }

    // MARK: - Fences

    private static let fenceLine = try! NSRegularExpression(pattern: #"(?m)^[ \t]{0,3}```"#)

    /// Models often wrap a whole document in a fence. Unwrap only when the
    /// evidence is unambiguous — a `markdown`/`md` info string, or exactly one
    /// fence pair spanning the entire reply — so a reply that legitimately *is*
    /// a code block survives intact.
    static func unwrappingWholeDocumentFence(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else { return reply }

        guard let firstNewline = trimmed.firstIndex(of: "\n") else { return reply }
        let info = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<firstNewline]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        let fenceCount = fenceLine.numberOfMatches(
            in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length))
        guard ["markdown", "md", ""].contains(info), fenceCount == 2 else { return reply }

        let inner = trimmed[trimmed.index(after: firstNewline)...]
        return String(inner.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func distinct(_ values: some Sequence<String>) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

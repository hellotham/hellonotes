//
//  MarkdownParsing.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import Markdown

/// A heading discovered in a note, used for outline / "Open Quickly" features.
/// `Codable` so parsed headings can persist in the collection index cache.
nonisolated struct DocumentHeading: Hashable, Codable {
    let level: Int
    let title: String
}

/// A `key: value` line from a note's YAML front matter.
nonisolated struct FrontMatterField: Hashable {
    let key: String
    let value: String
}

/// Pure, UI-agnostic Markdown parsing helpers (Core layer).
///
/// Wiki-links and hashtags are not part of GitHub-Flavored Markdown, so they
/// are extracted with regular expressions that mirror the editor's own
/// wiki-link storage pattern. Headings come from Apple's `swift-markdown` AST.
///
/// `nonisolated` so these pure functions can run off the main actor (the app
/// target defaults to main-actor isolation); the link graph parses files on a
/// background task.
nonisolated enum MarkdownParsing {

    /// Matches `[[Target]]` and `[[Target|Alias]]`, capturing the target in
    /// group 1. Mirrors the wiki-link storage pattern
    /// (an unescaped `!` prefix — an image — is excluded).
    private static let wikiLinkRegex = try! NSRegularExpression(
        pattern: #"(?<!!)\[\[([^\|\]\r\n]*)(?:\|[^\]\r\n]+)?\]\]"#
    )

    /// Matches `#tag` (letters, digits, `_`, `-`, `/`), not preceded by a word
    /// character (so it won't fire inside `foo#bar`).
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?<![\w])#([\p{L}0-9_][\p{L}0-9_/-]*)"#
    )

    /// The distinct wiki-link targets referenced by `text`, normalised: any
    /// `#heading` suffix removed and surrounding whitespace trimmed. Empty
    /// targets (e.g. a bare `[[]]`) are dropped. Order-preserving, de-duplicated.
    static func wikiLinkTargets(in text: String) -> [String] {
        matches(of: wikiLinkRegex, in: text, group: 1)
            .map { target in
                // `omittingEmptySubsequences: false` so an intra-document link
                // like `[[#Overview]]` splits to ["", "Overview"] and yields an
                // empty target (dropped below) — not a spurious link to "Overview".
                let withoutHeading = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
                return withoutHeading.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .uniqued()
    }

    /// The distinct hashtags in `text`, without the leading `#`.
    static func tags(in text: String) -> [String] {
        matches(of: tagRegex, in: text, group: 1).uniqued()
    }

    /// The note's alternate names, from an `aliases:` key in YAML front matter.
    /// Handles a flow list (`aliases: [A, B]`), a block list (`- A` lines), or a
    /// single scalar (`aliases: A`). Quotes are stripped; order preserved.
    static func aliases(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }

        var result: [String] = []
        var index = 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break } // end of front matter

            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "aliases" else {
                index += 1
                continue
            }

            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") {
                // Flow list: [A, B, C]
                let inner = value.dropFirst().drop { $0 == " " }
                let body = inner.hasSuffix("]") ? inner.dropLast() : inner[...]
                result = body.split(separator: ",").map { cleanScalar(String($0)) }.filter { !$0.isEmpty }
            } else if value.isEmpty {
                // Block list: subsequent `- item` lines.
                var j = index + 1
                while j < lines.count {
                    let itemLine = lines[j].trimmingCharacters(in: .whitespaces)
                    // A list item is `- x` or a bare `-` — not the closing `---` fence.
                    guard itemLine == "-" || itemLine.hasPrefix("- ") else { break }
                    let item = cleanScalar(String(itemLine.dropFirst()))
                    if !item.isEmpty { result.append(item) }
                    j += 1
                }
            } else {
                // Single scalar.
                let scalar = cleanScalar(value)
                if !scalar.isEmpty { result = [scalar] }
            }
            break
        }
        return result.uniqued()
    }

    /// Trim whitespace and surrounding single/double quotes from a YAML scalar.
    private static func cleanScalar(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where s.hasPrefix(quote) && s.hasSuffix(quote) && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Matches fenced ```mermaid blocks, capturing the diagram source (group 1).
    private static let mermaidRegex = try! NSRegularExpression(
        pattern: "```mermaid[ \\t]*\\n(.*?)\\n```",
        options: [.dotMatchesLineSeparators]
    )

    /// The Mermaid diagram sources found in fenced ```mermaid blocks.
    static func mermaidBlocks(in text: String) -> [String] {
        matches(of: mermaidRegex, in: text, group: 1)
    }

    /// Parse leading YAML front matter (a `---`-delimited block at the very top)
    /// into ordered `key: value` fields. Returns `nil` when there is no
    /// well-formed front matter (missing opening or closing `---`).
    static func frontMatter(in text: String) -> [FrontMatterField]? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var fields: [FrontMatterField] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                return fields // reached the closing delimiter → valid
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                fields.append(FrontMatterField(key: key, value: value))
            }
        }
        return nil // no closing delimiter → not front matter
    }

    /// The headings in `text`, in document order, parsed from the GFM AST.
    /// Authoritative but expensive (a full CommonMark parse) — use for a single
    /// note (the outline); bulk indexing uses ``fastHeadings(in:)``.
    static func headings(in text: String) -> [DocumentHeading] {
        var collector = HeadingCollector()
        collector.visit(Document(parsing: text))
        return collector.headings
    }

    /// Headings via a fence-aware line scan — an order of magnitude faster than
    /// the AST parse, for bulk indexing of whole collections. Covers ATX
    /// (`# Title`) and `=`-underline setext headings, and ignores fenced code.
    /// (`-`-underline setext is skipped: ambiguous with front matter and rules.)
    static func fastHeadings(in text: String) -> [DocumentHeading] {
        var result: [DocumentHeading] = []
        var inFence = false
        var previous: Substring = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" })

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                previous = ""
                continue
            }
            guard !inFence else { continue }

            if line.first == "#" {
                let hashes = line.prefix(while: { $0 == "#" })
                let rest = line.dropFirst(hashes.count)
                if hashes.count <= 6, rest.first == " " || rest.first == "\t" {
                    let title = rest.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty {
                        result.append(DocumentHeading(level: hashes.count, title: title))
                    }
                }
                previous = ""   // a heading can't be a setext base
                continue
            }
            if !line.isEmpty, line.allSatisfy({ $0 == "=" }), !previous.isEmpty {
                // Setext H1: a line of `=` under a text line.
                result.append(DocumentHeading(level: 1, title: previous.trimmingCharacters(in: .whitespaces)))
                previous = ""   // the underline is consumed
                continue
            }
            previous = line
        }
        return result
    }

    // MARK: - Private

    private static func matches(of regex: NSRegularExpression, in text: String, group: Int) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    private struct HeadingCollector: MarkupWalker {
        var headings: [DocumentHeading] = []
        mutating func visitHeading(_ heading: Heading) {
            headings.append(DocumentHeading(level: heading.level, title: heading.plainText))
        }
    }
}

private extension Array where Element: Hashable {
    /// De-duplicate while preserving first-seen order.
    nonisolated func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

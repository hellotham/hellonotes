//
//  NoteMarkdown.swift
//  GFMRender
//
//  A HelloNotes note is not quite GitHub-Flavored Markdown. It may open with
//  YAML front matter, and it may use Obsidian's `[[wiki links]]` and
//  `![[embeds]]` — neither of which cmark-gfm has ever heard of. This is the
//  step that turns a note into the document Preview renders.
//
//  It lives in the package, not in the app, because it is part of the *answer*
//  to "what does Preview show" and everything that asks that question has to
//  get the same answer. It used to live in the app alone (`GitHubMarkdown`), so
//  `RenderParity` — the gate that exists to prove Edit and Preview agree —
//  rendered its preview from the raw note and scored a `![[foo]]` as a
//  divergence the editor was never going to close. The two surfaces agreed
//  perfectly in the app the whole time; the harness was comparing a page
//  nobody is shown.
//

import Foundation
import MarkdownCore

/// Note dialect → plain GFM, for anything about to hand a note to
/// ``GFMRenderer``.
public enum NoteMarkdown {

    /// Prepare `text` (a full note) for GitHub-identical rendering: drop the
    /// front matter, rewrite the wiki constructs, leave everything else — it
    /// is already GFM — exactly as it was.
    public static func prepare(_ text: String) -> String {
        var out: [String] = []
        var fence: String? = nil          // the open ``` / ~~~ run, if any
        for line in body(of: text).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                out.append(line)
                if trimmed.hasPrefix(f) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == "`" || $0 == "~" }))
                out.append(line)
                continue
            }
            out.append(rewriteWikiConstructs(line))
        }
        return out.joined(separator: "\n")
    }

    /// The note without its leading front matter.
    ///
    /// Asked of ``BlockParser`` rather than re-derived, because the editor
    /// *folds* whatever the parser calls front matter and Preview *strips* it:
    /// two rules would be two answers, and the note where they differed would
    /// show a block of YAML on one surface and nothing on the other. (Two
    /// dashes are not front matter on their own — the block has to carry a
    /// `key:` — or a note opening with a horizontal rule would have everything
    /// down to its next rule deleted from Preview.)
    private static func body(of text: String) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return text }
        let parse = BlockParser.fullParse(ns)
        guard let first = parse.blocks.first, case .frontMatter = first.kind else { return text }
        return ns.substring(from: first.range.location + first.range.length)
    }

    /// Rewrite wiki constructs on a line, but leave inline code spans (`` `…` ``)
    /// verbatim — documentation of the wiki syntax like `` `[[Note]]` `` must
    /// render literally (as it does on GitHub), not as a link.
    private static func rewriteWikiConstructs(_ line: String) -> String {
        guard line.contains("`") else { return rewriteWikiLinks(line) }
        var out = ""
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == "`" {
                let open = idx
                var run = 0
                while idx < line.endIndex, line[idx] == "`" { run += 1; idx = line.index(after: idx) }
                let ticks = String(repeating: "`", count: run)
                if let close = line.range(of: ticks, range: idx..<line.endIndex) {
                    out += String(line[open..<close.upperBound])   // code span, verbatim
                    idx = close.upperBound
                } else {
                    out += ticks                                    // unterminated → literal
                }
            } else {
                let segStart = idx
                while idx < line.endIndex, line[idx] != "`" { idx = line.index(after: idx) }
                out += rewriteWikiLinks(String(line[segStart..<idx]))
            }
        }
        return out
    }

    /// `![[embed]]` → `![](embed)`, `[[target|alias]]` → `[alias](target)`.
    ///
    /// The two patterns are built here rather than held as `static let`s: a
    /// `Regex` is not `Sendable`, so at file scope in a Swift 6 module it is a
    /// concurrency error rather than a cache. The `contains("[[")` guard is
    /// what keeps that from mattering — a note's lines overwhelmingly do not
    /// hold a wiki link, and those never build a pattern at all.
    private static func rewriteWikiLinks(_ line: String) -> String {
        guard line.contains("[[") else { return line }
        // ![[ target (| alias)? ]]  — the alias is display-only, drop it for images.
        let embedRegex = /!\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/
        // [[ target (| alias)? ]]
        let wikiRegex = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/
        var s = line
        s = s.replacing(embedRegex) { match in
            "![](" + encode(String(match.1)) + ")"
        }
        s = s.replacing(wikiRegex) { match in
            let target = String(match.1)
            let alias = match.2.map(String.init) ?? target
            return "[\(alias)](" + encode(target) + ")"
        }
        return s
    }

    private static func encode(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

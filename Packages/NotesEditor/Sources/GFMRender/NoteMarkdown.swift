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
    ///
    /// What is front matter, and what is a table, are asked of ``BlockParser``
    /// rather than re-derived, because the editor answers both from it: it
    /// *folds* whatever the parser calls front matter and Preview *strips* it,
    /// and it lays out what the parser calls a table, unescaping the cells'
    /// pipes as it goes. Two rules would be two answers, and the note where
    /// they differed would show a block of YAML on one surface and nothing on
    /// the other, or link one note on one surface and another on the other.
    /// (Two dashes are not front matter on their own — the block has to carry
    /// a `key:` — or a note opening with a horizontal rule would have
    /// everything down to its next rule deleted from Preview.)
    public static func prepare(_ text: String) -> String {
        let ns = text as NSString
        let blocks = ns.length > 0 ? BlockParser.fullParse(ns).blocks : []
        var start = 0
        if let first = blocks.first, case .frontMatter = first.kind { start = NSMaxRange(first.range) }
        let tables = blocks.compactMap { block -> NSRange? in
            if case .table = block.kind { return block.range } else { return nil }
        }

        var out: [String] = []
        var fence: String? = nil          // the open ``` / ~~~ run, if any
        var next = start                  // where the next line starts in `text`
        for line in ns.substring(from: start).components(separatedBy: "\n") {
            let lineStart = next
            next += (line as NSString).length + 1
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
            let inTable = tables.contains { NSLocationInRange(lineStart, $0) }
            out.append(rewriteWikiConstructs(line, inTable: inTable))
        }
        return out.joined(separator: "\n")
    }

    /// Rewrite wiki constructs on a line, but leave inline code spans (`` `…` ``)
    /// verbatim — documentation of the wiki syntax like `` `[[Note]]` `` must
    /// render literally (as it does on GitHub), not as a link.
    private static func rewriteWikiConstructs(_ line: String, inTable: Bool) -> String {
        guard line.contains("`") else { return rewriteWikiLinks(line, inTable: inTable) }
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
                out += rewriteWikiLinks(String(line[segStart..<idx]), inTable: inTable)
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
    private static func rewriteWikiLinks(_ line: String, inTable: Bool) -> String {
        guard line.contains("[[") else { return line }
        // ![[ target (| alias)? ]]  — the alias is display-only, drop it for images.
        let embedRegex = /!\[\[([^\]|]+)(\|[^\]]+)?\]\]/
        // [[ target (| alias)? ]]
        let wikiRegex = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/
        var s = line
        s = s.replacing(embedRegex) { match in
            "![](" + encode(target(String(match.1), aliased: match.2 != nil, inTable: inTable)) + ")"
        }
        // A link's destination is a `hellonotes-wiki:` address, as Edit's is,
        // so a click on it is told from any other link's and followed to the
        // note (`GFMPreview.onLinkTap`). Given as a path, relative to the
        // note's folder, it was indistinguishable from `[report](report.pdf)`,
        // and following one creates the note it names.
        s = s.replacing(wikiRegex) { match in
            let alias = match.2.map(String.init)
            let name = target(String(match.1), aliased: alias != nil, inTable: inTable)
            return "[\(alias ?? name)](\(WikiLinkSyntax.urlScheme):" + encode(name) + ")"
        }
        return s
    }

    /// The target as written before the alias's pipe, read as the editor
    /// reads it. In a table the row is read first: a backslash directly
    /// before a pipe is the row's escape, and the cell holds the pipe without
    /// it (`GFMTableLayout.cells`, as cmark-gfm reads a row) — a table needs
    /// it, `[[Note\|alias]]`, or the pipe divides the cell. Then the link's
    /// own rule (`WikiLinkSyntax`): an escape left on the alias's pipe is not
    /// the target's, in a table or out of one. Left on, Preview linked
    /// `Note%5C` (implemented.md §51.33, §51.36).
    private static func target(_ written: String, aliased: Bool, inTable: Bool) -> String {
        var written = Substring(written)
        if inTable, aliased, written.last == "\\" { written = written.dropLast() }
        return String(WikiLinkSyntax.target(written: written, aliased: aliased))
    }

    private static func encode(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

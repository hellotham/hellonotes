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
        // ![[ target (| alias)? ]] — an alias has nowhere to show, and is
        // dropped; a picture's size is kept, as Obsidian sizes a Markdown
        // image, and the page reads it (`sizingPictures`).
        let embedRegex = /!\[\[([^\]|]+)(\|[^\]]+)?\]\]/
        // [[ target (| alias)? ]]
        let wikiRegex = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/
        var s = line
        s = s.replacing(embedRegex) { match in
            let name = target(String(match.1), aliased: match.2 != nil, inTable: inTable)
            // Escaped, as a table's row needs it; outside one cmark reads `\|`
            // as `|`.
            var size = ""
            if PictureNames.isPicture(name), let alias = match.2, let asked = PictureNames.sizeSuffix(of: alias) {
                size = "\\|\(asked.width)" + (asked.height.map { "x\($0)" } ?? "")
            }
            return "![" + size + "](" + encode(name) + ")"
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

// MARK: - Picture sizes

public extension NoteMarkdown {
    /// Obsidian's picture sizes, on a rendered page. Obsidian sizes a
    /// Markdown image in its description — `![A cat|300](cat.png)`,
    /// `![A cat|300x200](cat.png)`, `![|300](https://…)` — which cmark, as
    /// GitHub, writes as the description: `<img src="cat.png" alt="A cat|300"
    /// />`, at the picture's own size. This gives that `<img>` the size, and
    /// the description without it — the size Edit draws a picture in the
    /// collection at (`PictureNames`; Edit draws no picture from the web).
    ///
    /// After cmark, on its own output, where every form a destination, a
    /// title and a reference can take has been read into one: cmark writes an
    /// image one way only — `<img src="…" alt="…" />`, a title after the
    /// description, the description's quotes and angle brackets escaped — so
    /// each is found by its opening and read up to its `>`. (An `<img>`
    /// written by hand in exactly that shape is taken for one.) The size must
    /// be the last thing in the description, after a pipe, a whole number
    /// above nought (`PictureNames.sizeSuffix`, the rule Edit reads by).
    /// `GFMRenderer.html` is left as GitHub renders: the page is where the
    /// note's dialect is drawn.
    ///
    /// **Bytes, not a pattern.** A page carries its formulas, diagrams and
    /// cards inline, as `data:` addresses, and a long note's runs to tens of
    /// megabytes. A `Regex` over the whole page — and `String.contains`, its
    /// first guard — cost some tens of nanoseconds a byte, which held a long
    /// note's page in Split mode past the pause it is drawn at
    /// (`typingInSplitModeBarelyTouchesTheMainActor`, implemented.md §51.82).
    /// `memmem` and `memchr` look at a page at the speed of memory, and only
    /// an image's own tag is read as text.
    static func sizingPictures(_ html: String) -> String {
        var page = html
        let sized: [(range: Range<Int>, tag: String)] = page.withUTF8 { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return [] }
            let opening = Array("<img src=\"".utf8)
            var found: [(range: Range<Int>, tag: String)] = []
            var at = 0
            while at < bytes.count {
                guard let hit = memmem(base + at, bytes.count - at, opening, opening.count) else { break }
                let start = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                let afterOpening = start + opening.count
                guard afterOpening < bytes.count,
                      let close = memchr(base + afterOpening, Int32(UInt8(ascii: ">")), bytes.count - afterOpening)
                else { break }
                let stop = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(close)) + 1
                let tag = UnsafeBufferPointer(rebasing: bytes[start..<stop])
                if let resized = Self.sized(tag) { found.append((start..<stop, resized)) }
                at = stop
            }
            return found
        }
        guard !sized.isEmpty else { return html }
        return page.withUTF8 { bytes in
            var out = ""
            out.reserveCapacity(bytes.count + sized.count * 32)
            var at = 0
            for (range, tag) in sized {
                out += String(decoding: UnsafeBufferPointer(rebasing: bytes[at..<range.lowerBound]), as: UTF8.self)
                out += tag
                at = range.upperBound
            }
            out += String(decoding: UnsafeBufferPointer(rebasing: bytes[at..<bytes.count]), as: UTF8.self)
            return out
        }
    }

    /// `tag` — `<img src="…" alt="…" />`, a ` title="…"` perhaps after the
    /// description — with the size its description ends in made its width
    /// and height, or nil when it is not that shape or names no size.
    private static func sized(_ tag: UnsafeBufferPointer<UInt8>) -> String? {
        let text = String(decoding: tag, as: UTF8.self)
        let opening = "<img src=\""
        guard text.hasPrefix(opening), text.hasSuffix(" />"),
              let srcEnd = text[text.index(text.startIndex, offsetBy: opening.count)...].firstIndex(of: "\"")
        else { return nil }
        let afterSrc = text[srcEnd...]
        guard afterSrc.hasPrefix("\" alt=\"") else { return nil }
        let altStart = text.index(srcEnd, offsetBy: 7)
        guard let altEnd = text[altStart...].firstIndex(of: "\"") else { return nil }
        let alt = text[altStart..<altEnd]
        let rest = text[text.index(after: altEnd)...]   // ` />` or ` title="…" />`
        guard rest == " />" || (rest.hasPrefix(" title=\"") && rest.hasSuffix("\" />")),
              let pipe = alt.lastIndex(of: "|"),
              let size = PictureNames.sizeSuffix(of: alt) else { return nil }
        var out = String(text[..<altStart]) + alt[..<pipe] + "\" width=\"\(size.width)\""
        if let height = size.height { out += " height=\"\(height)\"" }
        return out + rest
    }
}

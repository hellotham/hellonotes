//
//  GFMLiveStyle.swift
//  MarkdownEditor
//
//  Produces the live editor's style runs from cmark-gfm's spec-perfect AST —
//  the same engine the Preview renders with. This makes the editor's rendered
//  (caret-away) state GFM-conformant and consistent with the Preview, while
//  the syntax markers conceal with `.whenInactive` so moving the caret into a
//  construct reveals its Markdown source (Obsidian/Bear style).
//

import Foundation
import MarkdownCore
import GFMRender

nonisolated public enum GFMLiveStyle {

    /// Spec-accurate style runs for the whole document.
    public static func runs(_ text: NSString) -> [StyleRun] {
        let source = text as String
        let nodes = GFMRenderer.nodes(source)
        var runs: [StyleRun] = []
        runs.reserveCapacity(nodes.count * 2)
        for node in nodes {
            emit(node, text: text, into: &runs)
        }
        return runs
    }

    /// The length of a setext heading's *text*, with the `===` / `---`
    /// underline (and the newline before it) trimmed off.
    private static func setextTextLength(_ range: NSRange, in text: NSString) -> Int {
        var end = range.location + range.length
        // Back over any trailing whitespace, then over the underline itself.
        while end > range.location, isSpace(text.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > range.location {
            let c = text.character(at: start - 1)
            guard c == 0x3D || c == 0x2D else { break }   // '=' or '-'
            start -= 1
        }
        guard start < end else { return range.length }    // no underline found
        // Everything left of the underline, minus the newline that ends the
        // text line and any indentation before the underline.
        var textEnd = start
        while textEnd > range.location, isSpace(text.character(at: textEnd - 1)) { textEnd -= 1 }
        return max(0, textEnd - range.location)
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    /// Block-level cmark node kinds — everything that occupies vertical space
    /// in the rendered document.
    private static let blockKinds: Set<String> = [
        "block_quote", "list", "item", "code_block", "html_block", "custom_block",
        "paragraph", "heading", "thematic_break", "table", "table_row",
        "table_cell", "footnote_definition",
    ]

    /// Source that the rendered document has no equivalent for.
    ///
    /// A link reference definition — `[foo]: /url "title"` — is consumed by the
    /// parser and emits nothing at all, so the Preview shows a blank where the
    /// editor showed two lines of source. Rather than teach the editor to
    /// recognise that one construct, ask cmark what it *kept*: any run of
    /// non-blank source no block node covers is source the reader will never
    /// see, and the editor collapses it the way it already collapses a setext
    /// underline.
    public static func unrenderedRanges(_ text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [] }
        var covered = [Bool](repeating: false, count: text.length)
        for node in GFMRenderer.nodes(text as String) where blockKinds.contains(node.kind) {
            let r = node.range
            guard r.location >= 0, r.length > 0, r.location + r.length <= text.length else { continue }
            for i in r.location..<(r.location + r.length) { covered[i] = true }
        }
        // Maximal runs of uncovered source, opened by the first non-blank
        // character and closed only by a covered one. Not closed at newlines:
        // a reference definition may wrap over several lines, and a range that
        // ends at every line break cannot contain the block that holds it.
        var out: [NSRange] = []
        var start: Int?
        for i in 0..<text.length {
            let c = text.character(at: i)
            let blank = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
            if covered[i] {
                if let s = start { out.append(NSRange(location: s, length: i - s)); start = nil }
            } else if !blank, start == nil {
                start = i
            }
        }
        if let s = start { out.append(NSRange(location: s, length: text.length - s)) }
        return out
    }

    private static func emit(_ node: GFMNode, text: NSString, into runs: inout [StyleRun]) {
        let r = node.range
        guard r.length >= 0, r.location >= 0, r.location + r.length <= text.length else { return }

        switch node.kind {
        case "heading":
            // ATX: leading run of `#` + optional spaces is the marker; the rest
            // is heading text. Setext: no leading `#`, style the whole line.
            let level = max(1, min(6, node.headingLevel))
            if r.length > 0, text.character(at: r.location) == 0x23 {   // '#'
                var i = r.location
                let end = r.location + r.length
                while i < end, text.character(at: i) == 0x23 { i += 1 }
                while i < end, text.character(at: i) == 0x20 { i += 1 }
                append(&runs, r.location, i - r.location, .marker, .whenInactive)
                append(&runs, i, end - i, .headingText(level: level))
            } else {
                // Setext. cmark's node covers the underline as well as the
                // text, and this overlay runs *after* `StyleSpec` has concealed
                // that underline — so styling the whole node put the heading's
                // own font back on it. It stayed invisible until a line long
                // enough to wrap at the heading size appeared, at which point
                // the concealed underline silently occupied two lines.
                append(&runs, r.location, setextTextLength(r, in: text),
                       .headingText(level: level))
            }

        case "strong":
            delimited(r, open: 2, close: 2, content: .strong, text: text, into: &runs)
        case "emph":
            delimited(r, open: 1, close: 1, content: .emphasis, text: text, into: &runs)
        case "strikethrough":
            delimited(r, open: 2, close: 2, content: .strikethrough, text: text, into: &runs)

        case "code":
            // cmark reports the *content* span; backticks sit just outside.
            let open = backtickRun(text, before: r.location)
            let close = backtickRun(text, after: r.location + r.length)
            if open > 0 { append(&runs, r.location - open, open, .marker, .whenInactive) }
            append(&runs, r.location, r.length, .inlineCode)
            if close > 0 { append(&runs, r.location + r.length, close, .marker, .whenInactive) }

        case "link", "image":
            // `[label](url)` / `![label](url)`: conceal `![`? and `](url)` tail,
            // colour the label. Find the `](` that begins the destination.
            emitLink(node, text: text, into: &runs)

        case "code_block":
            emitCodeBlock(r, info: node.info, text: text, into: &runs)

        case "block_quote":
            // Marker concealment + bar handling stays with the block layer;
            // here just tint the quoted text.
            break

        case "thematic_break":
            append(&runs, r.location, trimmedLen(text, r), .thematicBreak)

        case "text", "paragraph", "list", "item", "document",
             "table", "table_row", "table_cell", "table_header",
             "softbreak", "linebreak", "html_block", "html_inline":
            break   // structure handled elsewhere / no inline styling needed

        default:
            break
        }
    }

    // MARK: - Helpers

    private static func delimited(_ r: NSRange, open: Int, close: Int, content: TextRole,
                                  text: NSString, into runs: inout [StyleRun]) {
        guard r.length >= open + close else {
            append(&runs, r.location, r.length, content); return
        }
        append(&runs, r.location, open, .marker, .whenInactive)
        append(&runs, r.location + open, r.length - open - close, content)
        append(&runs, r.location + r.length - close, close, .marker, .whenInactive)
    }

    private static func emitLink(_ node: GFMNode, text: NSString, into runs: inout [StyleRun]) {
        let r = node.range
        let end = r.location + r.length
        // Opening `[` (link) or `![` (image).
        let isImage = end > r.location && text.character(at: r.location) == 0x21 /* ! */
        let openLen = isImage ? 2 : 1
        guard r.length > openLen else {
            append(&runs, r.location, r.length, .linkText); return
        }
        let labelStart = r.location + openLen
        // The label's closing `]` — first unescaped `]` after the opener. Then
        // whatever follows (`(url)`, `[ref]`, or nothing) is the concealed tail.
        var j = labelStart
        while j < end, text.character(at: j) != 0x5D /* ] */ { j += 1 }
        guard j < end else {
            append(&runs, r.location, r.length, .linkText); return
        }
        append(&runs, r.location, openLen, .marker, .whenInactive)      // '[' / '!['
        append(&runs, labelStart, j - labelStart, .linkText)           // label
        append(&runs, j, end - j, .marker, .whenInactive)              // ']…' tail
    }

    private static func emitCodeBlock(_ r: NSRange, info: String, text: NSString,
                                      into runs: inout [StyleRun]) {
        let end = r.location + r.length
        // Fenced? First non-space char on the first line is ` or ~.
        var i = r.location
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        let fenced = i < end && (text.character(at: i) == 0x60 || text.character(at: i) == 0x7E)
        if fenced {
            // Opening fence line → marker; body → codeBlock; closing fence → marker.
            let firstNL = rangeOfNewline(text, from: r.location, to: end)
            let openEnd = firstNL == NSNotFound ? end : firstNL + 1
            append(&runs, r.location, openEnd - r.location, .marker)
            if !info.isEmpty {
                // info string sits at the end of the open line.
                let infoLen = (info as NSString).length
                append(&runs, openEnd - 1 - infoLen, infoLen, .codeInfo)
            }
            append(&runs, openEnd, max(0, end - openEnd), .codeBlock)
        } else {
            append(&runs, r.location, r.length, .codeBlock)
        }
    }

    private static func append(_ runs: inout [StyleRun], _ loc: Int, _ len: Int,
                               _ role: TextRole, _ concealment: Concealment = .never) {
        guard len > 0 else { return }
        runs.append(StyleRun(range: NSRange(location: loc, length: len), role: role, concealment: concealment))
    }

    private static func backtickRun(_ text: NSString, before end: Int) -> Int {
        var n = 0, i = end - 1
        while i >= 0, text.character(at: i) == 0x60 { n += 1; i -= 1 }
        return n
    }
    private static func backtickRun(_ text: NSString, after start: Int) -> Int {
        var n = 0, i = start
        while i < text.length, text.character(at: i) == 0x60 { n += 1; i += 1 }
        return n
    }
    private static func rangeOfNewline(_ text: NSString, from: Int, to: Int) -> Int {
        var i = from
        while i < to { if text.character(at: i) == 0x0A { return i }; i += 1 }
        return NSNotFound
    }
    private static func trimmedLen(_ text: NSString, _ r: NSRange) -> Int {
        var len = r.length
        while len > 0, text.character(at: r.location + len - 1) == 0x0A { len -= 1 }
        return len
    }
}

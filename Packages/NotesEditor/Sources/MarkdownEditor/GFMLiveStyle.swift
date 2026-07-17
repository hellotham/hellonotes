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
                append(&runs, r.location, r.length, .headingText(level: level))
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
        let isImage = node.kind == "image"
        // Opening `[` (or `![`).
        let openLen = isImage ? 2 : 1
        // Find the closing `]( … )` — scan from the end for the last ')'.
        // The label spans from after '[' to the matching ']'; simplest robust
        // approach: locate "](" inside the range.
        let inner = text.substring(with: r) as NSString
        let destMarker = inner.range(of: "](")
        guard destMarker.location != NSNotFound,
              r.length >= openLen, text.character(at: end - 1) == 0x29 /* ) */ else {
            append(&runs, r.location, r.length, isImage ? .marker : .linkText); return
        }
        let labelStart = r.location + openLen
        let labelEnd = r.location + destMarker.location            // index of ']'
        append(&runs, r.location, openLen, .marker, .whenInactive)  // '[' / '!['
        if labelEnd > labelStart {
            append(&runs, labelStart, labelEnd - labelStart, isImage ? .linkText : .linkText)
        }
        append(&runs, labelEnd, end - labelEnd, .marker, .whenInactive)  // ']( url )'
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

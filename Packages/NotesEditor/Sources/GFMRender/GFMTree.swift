//
//  GFMTree.swift
//  GFMRender
//
//  Walks cmark-gfm's spec-perfect parse tree with source positions, so the
//  live editor can style text from the *same* engine the Preview renders with
//  — guaranteeing the editor is GFM-spec-conformant and consistent with the
//  Preview. Source positions map every node back to its byte range in the
//  original Markdown.
//

import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// A parsed node: its kind, its UTF-16 range in the source, and nesting depth.
public struct GFMNode: Sendable, Equatable {
    public var kind: String          // cmark node type name (e.g. "heading")
    public var range: NSRange        // UTF-16 range in the original string
    public var depth: Int            // nesting depth in the tree
    public var headingLevel: Int     // for headings; else 0
    public var listOrdered: Bool     // for list/item context
    public var info: String          // fence info string / link url, when useful
}

public extension GFMRenderer {

    /// Parse `markdown` and return every block/inline node with its source
    /// range (UTF-16 offsets into `markdown`). Spec-perfect (cmark-gfm).
    static func nodes(_ markdown: String) -> [GFMNode] {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_DEFAULT | CMARK_OPT_UNSAFE

        guard let parser = cmark_parser_new(options) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        let bytes = Array(markdown.utf8)
        bytes.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    cmark_parser_feed(parser, $0, buf.count)
                }
            }
        }
        guard let doc = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(doc) }

        let lineMap = ByteLineMap(utf8: bytes, source: markdown)
        var out: [GFMNode] = []
        guard let iter = cmark_iter_new(doc) else { return [] }
        defer { cmark_iter_free(iter) }
        var depth = 0
        while true {
            let ev = cmark_iter_next(iter)
            if ev == CMARK_EVENT_DONE { break }
            guard let node = cmark_iter_get_node(iter) else { continue }
            let type = cmark_node_get_type(node)
            if ev == CMARK_EVENT_EXIT { depth -= 1; continue }
            // ENTER
            defer { if cmark_node_first_child(node) != nil { depth += 1 } }
            guard type != CMARK_NODE_DOCUMENT else { continue }

            let startLine = Int(cmark_node_get_start_line(node))
            let startCol = Int(cmark_node_get_start_column(node))
            let endLine = Int(cmark_node_get_end_line(node))
            let endCol = Int(cmark_node_get_end_column(node))
            guard let range = lineMap.range(startLine: startLine, startCol: startCol,
                                            endLine: endLine, endCol: endCol) else { continue }
            let name = String(cString: cmark_node_get_type_string(node))
            out.append(GFMNode(
                kind: name, range: range, depth: depth,
                headingLevel: type == CMARK_NODE_HEADING ? Int(cmark_node_get_heading_level(node)) : 0,
                listOrdered: type == CMARK_NODE_LIST ? cmark_node_get_list_type(node) == CMARK_ORDERED_LIST : false,
                info: infoString(node, type)))
        }
        return out
    }

    private static func infoString(_ node: UnsafeMutablePointer<cmark_node>!, _ type: cmark_node_type) -> String {
        if type == CMARK_NODE_CODE_BLOCK, let s = cmark_node_get_fence_info(node) { return String(cString: s) }
        if type == CMARK_NODE_LINK || type == CMARK_NODE_IMAGE, let s = cmark_node_get_url(node) { return String(cString: s) }
        return ""
    }
}

/// Maps cmark's 1-based (line, byte-column) positions to UTF-16 offsets.
/// Precomputes, per line start, both the byte offset and the UTF-16 offset,
/// so each lookup only scans within a single line — O(document) total, not
/// O(document × nodes).
struct ByteLineMap {
    private let lineStartByte: [Int]     // byte offset where 1-based line i begins
    private let lineStartUTF16: [Int]    // UTF-16 offset where 1-based line i begins
    private let utf8: [UInt8]

    init(utf8: [UInt8], source: String) {
        self.utf8 = utf8
        var starts = [0]
        var u16Starts = [0]
        var u16 = 0
        var i = 0
        let n = utf8.count
        while i < n {
            let b = utf8[i]
            let (step, units): (Int, Int) =
                b < 0x80 ? (1, 1) : b < 0xE0 ? (2, 1) : b < 0xF0 ? (3, 1) : (4, 2)
            u16 += units
            i += step
            if b == 0x0A { starts.append(i); u16Starts.append(u16) }
        }
        lineStartByte = starts
        lineStartUTF16 = u16Starts
    }

    /// Convert a (line, byteColumn) — both 1-based, column pointing at the
    /// first byte of the char — to a UTF-16 offset. Scans only within the line.
    private func utf16Offset(line: Int, col: Int) -> Int? {
        guard line >= 1, line <= lineStartByte.count else { return nil }
        let lineByte = lineStartByte[line - 1]
        let target = lineByte + max(0, col - 1)
        guard target >= 0, target <= utf8.count else { return nil }
        var u16 = lineStartUTF16[line - 1]
        var i = lineByte
        while i < target {
            let b = utf8[i]
            if b < 0x80 { i += 1; u16 += 1 }
            else if b < 0xE0 { i += 2; u16 += 1 }
            else if b < 0xF0 { i += 3; u16 += 1 }
            else { i += 4; u16 += 2 }
        }
        return u16
    }

    func range(startLine: Int, startCol: Int, endLine: Int, endCol: Int) -> NSRange? {
        guard startLine > 0, endLine > 0,
              let lo = utf16Offset(line: startLine, col: startCol),
              // cmark end column points AT the last char; range end is +1 char.
              let hiStart = utf16Offset(line: endLine, col: endCol) else { return nil }
        // Include the last character: advance one grapheme's UTF-16 length.
        let hi = utf16Offset(line: endLine, col: endCol + 1) ?? hiStart
        guard hi >= lo else { return NSRange(location: lo, length: 0) }
        return NSRange(location: lo, length: hi - lo)
    }
}

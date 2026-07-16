//
//  BlockParser.swift
//  MarkdownCore
//
//  The incremental block parser. Two entry points with one invariant:
//
//      incremental(edit) == fullParse(newText)        (fuzz-tested)
//
//  Full parse walks every line once. Incremental parse re-walks only the
//  damaged block neighborhood and *splices*: it starts one block before the
//  edit (context rules — setext underlines, table delimiter rows — look one
//  line back) and walks forward until the new block boundaries realign with
//  the old ones, then keeps the old tail with shifted offsets. Edits that
//  genuinely change everything downstream (opening an unclosed fence) walk
//  to EOF — that O(rest) cost is inherent, not accidental.
//
//  The classifier is editor-grade Markdown, not spec-grade CommonMark: the
//  goal is stable, predictable styling at interactive latency. Export paths
//  use swift-markdown, where spec fidelity matters.
//

import Foundation

public enum BlockParser {

    // MARK: - Full parse

    public static func fullParse(_ text: NSString) -> ParseResult {
        let lines = LineIndex(text: text)
        let blocks = parseLines(text, lines: lines, from: 0, stopAt: nil)?.blocks ?? []
        return ParseResult(lines: lines, blocks: blocks)
    }

    // MARK: - Incremental parse

    public static func incremental(
        _ text: NSString,
        edit: TextEdit,
        previous: ParseResult
    ) -> ParseResult {
        var lines = previous.lines
        lines.apply(edit, newText: text)

        guard !previous.blocks.isEmpty else {
            let blocks = parseLines(text, lines: lines, from: 0, stopAt: nil)?.blocks ?? []
            return ParseResult(lines: lines, blocks: blocks)
        }

        // --- 1. Damage window in old-block terms -------------------------
        let oldBlocks = previous.blocks
        let editStart = edit.range.location
        let oldEditEnd = edit.range.location + edit.range.length

        var firstDamaged = previous.blockIndex(at: editStart) ?? 0
        var lastDamaged = previous.blockIndex(at: max(oldEditEnd, editStart)) ?? (oldBlocks.count - 1)
        // A pure insertion at a block boundary can extend the block that
        // *ends* there (typing at the end of a paragraph's trailing newline
        // belongs to the next line, which blockIndex already resolves — but
        // an edit touching a block's first character can also merge it into
        // the previous block, e.g. deleting the blank line between two
        // paragraphs). One block of slack on each side keeps this simple.
        if firstDamaged > 0 { firstDamaged -= 1 }
        if lastDamaged < oldBlocks.count - 1 { lastDamaged += 1 }

        // Front matter is the one long-range rule (it hinges on line 0, and
        // recognizing it needs its closing fence). If the document starts
        // with `---` and the edit lands anywhere in the region a front
        // matter block could span, reparse from the top.
        if firstDamaged > 0,
           previous.lines.lineNumber(at: editStart) <= frontMatterSearchLimit,
           text.length >= 3, isDashFence(text, lineRange: lines.lineRange(0)) {
            firstDamaged = 0
        }

        let startLine = oldBlocks[firstDamaged].firstLine
        let delta = edit.delta
        let lineDelta = lines.lineCount - previous.lines.lineCount

        // --- 2. Old tail candidates for convergence ----------------------
        // Old blocks strictly after the damage window, with the offsets they
        // will have in the new text. The walk stops as soon as it starts a
        // fresh block exactly at one of these starts.
        var tailIndex = lastDamaged + 1
        func tailStartInNewText(_ i: Int) -> Int { oldBlocks[i].range.location + delta }

        // --- 3. Re-walk from the damage start until convergence ----------
        let walk = parseLines(text, lines: lines, from: startLine, stopAt: { newBlockStart in
            while tailIndex < oldBlocks.count && tailStartInNewText(tailIndex) < newBlockStart {
                tailIndex += 1
            }
            return tailIndex < oldBlocks.count && tailStartInNewText(tailIndex) == newBlockStart
        })

        var blocks = Array(oldBlocks[..<firstDamaged])
        if let walk {
            blocks.append(contentsOf: walk.blocks)
            if walk.converged {
                for i in tailIndex..<oldBlocks.count {
                    var b = oldBlocks[i]
                    b.range.location += delta
                    b.firstLine += lineDelta
                    blocks.append(b)
                }
            }
        }
        return ParseResult(lines: lines, blocks: blocks)
    }

    // MARK: - The line walk

    private struct Walk {
        var blocks: [Block]
        var converged: Bool
    }

    /// Classify lines from `from`, building blocks. When `stopAt` returns
    /// true for a fresh block's start offset, stop and report convergence.
    /// Returns nil only for the empty document (no lines to walk is
    /// impossible — LineIndex always has one line).
    private static func parseLines(
        _ text: NSString,
        lines: LineIndex,
        from startLine: Int,
        stopAt: ((Int) -> Bool)?
    ) -> Walk? {
        var builder = BlockBuilder(text: text, lines: lines)
        var cursor = LineCursor(text: text)
        var line = startLine

        // Front matter can only begin at the very first line.
        if line == 0, lines.lineCount > 1, isDashFence(text, lineRange: lines.lineRange(0)) {
            var close: Int? = nil
            for i in 1..<min(lines.lineCount, frontMatterSearchLimit) where isDashFence(text, lineRange: lines.lineRange(i)) {
                close = i; break
            }
            if let close {
                builder.emit(kind: .frontMatter, fromLine: 0, throughLine: close)
                line = close + 1
            }
        }

        while line < lines.lineCount {
            // Convergence check happens only at fresh block boundaries.
            if let stopAt, builder.isAtBoundary, line > startLine {
                let offset = lines.lineRange(line).location
                if stopAt(offset) {
                    return Walk(blocks: builder.finish(), converged: true)
                }
            }

            let info = cursor.classify(lineRange: lines.contentRange(line, in: text))
            line = builder.consume(line: line, info: info, cursor: &cursor)
        }
        // Also allow convergence exactly at end-of-walk (an edit at EOF).
        return Walk(blocks: builder.finish(), converged: false)
    }

    static let frontMatterSearchLimit = 200

    /// A line that is exactly `---` (with up to 3 leading spaces, trailing
    /// whitespace allowed) — the front matter fence.
    static func isDashFence(_ text: NSString, lineRange: NSRange) -> Bool {
        var i = lineRange.location
        var end = lineRange.location + lineRange.length
        if end > i && text.character(at: end - 1) == 0x0A { end -= 1 }
        var spaces = 0
        while i < end && text.character(at: i) == 0x20 { i += 1; spaces += 1 }
        guard spaces <= 3 else { return false }
        var dashes = 0
        while i < end && text.character(at: i) == 0x2D { i += 1; dashes += 1 }
        guard dashes == 3 else { return false }
        while i < end {
            let c = text.character(at: i)
            guard c == 0x20 || c == 0x09 else { return false }
            i += 1
        }
        return true
    }
}

// MARK: - Line classification

/// What a single line looks like, before block context is applied.
struct LineInfo {
    enum Kind {
        case blank
        case atxHeading(level: Int)
        case fenceDelimiter(marker: unichar, count: Int, info: String)
        case mathDelimiter(selfClosed: Bool)
        case quote(callout: String?)
        case listMarker(ListInfo)
        case thematicBreak
        /// All `=` (level 1) or all `-` (level 2) — setext *candidate*;
        /// meaning depends on whether a paragraph is open.
        case setextUnderline(level: Int)
        case pipeRow(isDelimiterRow: Bool)
        case text
    }
    var kind: Kind
    var indent: Int
}

/// Classifies one line at a time from a reusable buffer — the only place
/// characters are read. Copies each visited line once (bulk copy), so the
/// walk's cost is proportional to lines visited, never document size.
struct LineCursor {
    let text: NSString
    private var buffer: [unichar] = []

    init(text: NSString) { self.text = text }

    mutating func classify(lineRange: NSRange) -> LineInfo {
        let len = lineRange.length
        if buffer.count < len { buffer = [unichar](repeating: 0, count: max(len, 256)) }
        if len > 0 {
            buffer.withUnsafeMutableBufferPointer { buf in
                text.getCharacters(buf.baseAddress!, range: lineRange)
            }
        }
        return Self.classify(buffer, count: len)
    }

    static func classify(_ b: [unichar], count: Int) -> LineInfo {
        var i = 0
        while i < count, b[i] == 0x20 { i += 1 }         // leading spaces
        let indent = i
        // Tabs at line start: treat a tab-indented line as indented content.
        if i < count, b[i] == 0x09 {
            return LineInfo(kind: .text, indent: indent + 4)
        }
        if i == count { return LineInfo(kind: .blank, indent: 0) }

        let c = b[i]
        let deepIndent = indent >= 4

        // Structural syntax needs ≤3 spaces of indent (CommonMark rule kept
        // because it protects indented continuation content inside lists).
        if !deepIndent {
            switch c {
            case 0x23: // '#'
                var level = 0, j = i
                while j < count, b[j] == 0x23, level < 7 { level += 1; j += 1 }
                if level <= 6, j == count || b[j] == 0x20 || b[j] == 0x09 {
                    return LineInfo(kind: .atxHeading(level: level), indent: indent)
                }
            case 0x60, 0x7E: // '`' '~'
                var j = i, n = 0
                while j < count, b[j] == c { n += 1; j += 1 }
                if n >= 3 {
                    // Info string: rest of line, trimmed.
                    var lo = j, hi = count
                    while lo < hi, b[lo] == 0x20 || b[lo] == 0x09 { lo += 1 }
                    while hi > lo, b[hi-1] == 0x20 || b[hi-1] == 0x09 || b[hi-1] == 0x0D { hi -= 1 }
                    let info = lo < hi ? String(utf16CodeUnits: Array(b[lo..<hi]), count: hi - lo) : ""
                    return LineInfo(kind: .fenceDelimiter(marker: c, count: n, info: info), indent: indent)
                }
            case 0x24: // '$'
                if i + 1 < count, b[i+1] == 0x24 {
                    // `$$` opener; `$$ … $$` on one line self-closes.
                    var j = i + 2
                    var closed = false
                    while j + 1 < count {
                        if b[j] == 0x24 && b[j+1] == 0x24 { closed = true; break }
                        j += 1
                    }
                    let hasContentAfter = i + 2 < count
                    return LineInfo(kind: .mathDelimiter(selfClosed: closed && hasContentAfter), indent: indent)
                }
            case 0x3E: // '>'
                // Callout when content begins `[!type]`.
                var j = i + 1
                if j < count, b[j] == 0x20 { j += 1 }
                var callout: String? = nil
                if j + 1 < count, b[j] == 0x5B, b[j+1] == 0x21 { // "[!"
                    var k = j + 2
                    var name: [unichar] = []
                    while k < count, b[k] != 0x5D { name.append(b[k]); k += 1 }
                    if k < count, !name.isEmpty {
                        callout = String(utf16CodeUnits: name, count: name.count).lowercased()
                    }
                }
                return LineInfo(kind: .quote(callout: callout), indent: indent)
            default:
                break
            }

            // Thematic break / setext candidates: a run of one repeated
            // marker char (with optional internal spaces for breaks).
            if c == 0x3D { // '='
                var j = i, ok = true
                while j < count { if b[j] != 0x3D { ok = false; break }; j += 1 }
                if ok { return LineInfo(kind: .setextUnderline(level: 1), indent: indent) }
            }
            if c == 0x2D || c == 0x2A || c == 0x5F { // '-' '*' '_'
                var j = i, marks = 0, others = false
                while j < count {
                    if b[j] == c { marks += 1 }
                    else if b[j] == 0x20 || b[j] == 0x09 { /* allowed */ }
                    else { others = true; break }
                    j += 1
                }
                if !others {
                    // Pure dashes with no spaces: setext-2 candidate (the
                    // builder decides vs thematic break by paragraph state).
                    if c == 0x2D && marks >= 1 {
                        var pure = true
                        for k in i..<count where b[k] != 0x2D { pure = false; break }
                        if pure {
                            return LineInfo(kind: .setextUnderline(level: 2), indent: indent)
                        }
                    }
                    if marks >= 3 {
                        return LineInfo(kind: .thematicBreak, indent: indent)
                    }
                }
            }
        }

        // List markers: `- `, `* `, `+ `, `12. `, `12) ` at any indent.
        if c == 0x2D || c == 0x2A || c == 0x2B {
            if i + 1 == count || b[i+1] == 0x20 {
                return LineInfo(kind: .listMarker(listInfo(b, count: count, indent: indent, markerLength: 1, ordered: false)), indent: indent)
            }
        }
        if c >= 0x30, c <= 0x39 {
            var j = i, digits = 0
            while j < count, b[j] >= 0x30, b[j] <= 0x39, digits < 9 { digits += 1; j += 1 }
            if j < count, b[j] == 0x2E || b[j] == 0x29 {
                if j + 1 == count || b[j+1] == 0x20 {
                    return LineInfo(kind: .listMarker(listInfo(b, count: count, indent: indent, markerLength: digits + 1, ordered: true)), indent: indent)
                }
            }
        }

        // Pipe rows (tables). A delimiter row is `|---|:---:|…`.
        if hasUnescapedPipe(b, from: i, count: count) {
            return LineInfo(kind: .pipeRow(isDelimiterRow: isDelimiterRow(b, from: i, count: count)), indent: indent)
        }

        return LineInfo(kind: .text, indent: indent)
    }

    private static func listInfo(_ b: [unichar], count: Int, indent: Int, markerLength: Int, ordered: Bool) -> ListInfo {
        var content = indent + markerLength
        if content < count, b[content] == 0x20 { content += 1 }
        var task: TaskState? = nil
        // `[ ] ` / `[x] ` immediately after the marker.
        if content + 2 < count, b[content] == 0x5B, b[content+2] == 0x5D {
            let inner = b[content+1]
            if inner == 0x20 { task = .unchecked }
            if inner == 0x78 || inner == 0x58 { task = .checked } // x / X
            if task != nil {
                content += 3
                if content < count, b[content] == 0x20 { content += 1 }
            }
        }
        return ListInfo(indent: indent, markerLength: markerLength, isOrdered: ordered, task: task, contentOffset: content)
    }

    private static func hasUnescapedPipe(_ b: [unichar], from: Int, count: Int) -> Bool {
        var i = from
        while i < count {
            if b[i] == 0x7C, i == 0 || b[i-1] != 0x5C { return true }
            i += 1
        }
        return false
    }

    private static func isDelimiterRow(_ b: [unichar], from: Int, count: Int) -> Bool {
        // Cells of `:? -+ :?` separated by pipes; at least one dash overall.
        var sawDash = false
        var i = from
        while i < count {
            switch b[i] {
            case 0x7C, 0x3A, 0x20, 0x09: break
            case 0x2D: sawDash = true
            case 0x0D: break
            default: return false
            }
            i += 1
        }
        return sawDash
    }
}

// MARK: - Block building

/// Folds classified lines into blocks, applying the context rules
/// (paragraph continuation, setext conversion, fence interiors, list
/// continuation, table shape).
private struct BlockBuilder {
    let text: NSString
    let lines: LineIndex

    private var blocks: [Block] = []

    private enum Open {
        case none
        case paragraph(fromLine: Int)
        case fence(fromLine: Int, marker: unichar, count: Int, info: String)
        case math(fromLine: Int)
        case quote(fromLine: Int, callout: String?)
        case list(fromLine: Int, info: ListInfo)
        case table(fromLine: Int, sawDelimiter: Bool)
        case blank(fromLine: Int)
    }
    private var open: Open = .none
    private var lastLine = 0

    init(text: NSString, lines: LineIndex) {
        self.text = text
        self.lines = lines
    }

    var isAtBoundary: Bool {
        if case .none = open { return true }
        return false
    }

    /// Consume `line` (already classified); returns the next line to visit.
    mutating func consume(line: Int, info: LineInfo, cursor: inout LineCursor) -> Int {
        lastLine = line

        // Fence and math interiors swallow everything until their close.
        switch open {
        case .fence(let from, let marker, let count, let fenceInfo):
            if case .fenceDelimiter(let m, let n, let closeInfo) = info.kind,
               m == marker, n >= count, closeInfo.isEmpty {
                blocks.append(make(.fencedCode(info: fenceInfo, closed: true), from, line))
                open = .none
            }
            return line + 1
        case .math(let from):
            if lineContainsMathClose(line) {
                blocks.append(make(.mathBlock(closed: true), from, line))
                open = .none
            }
            return line + 1
        default:
            break
        }

        switch info.kind {
        case .blank:
            closeOpen(through: line - 1)
            if case .blank(let from) = open {
                open = .blank(fromLine: from)      // extend the run
            } else {
                open = .blank(fromLine: line)
            }
            return line + 1

        case .atxHeading(let level):
            closeOpen(through: line - 1)
            blocks.append(make(.heading(level: level, setext: false), line, line))
            return line + 1

        case .fenceDelimiter(let marker, let count, let fenceInfo):
            closeOpen(through: line - 1)
            open = .fence(fromLine: line, marker: marker, count: count, info: fenceInfo)
            return line + 1

        case .mathDelimiter(let selfClosed):
            closeOpen(through: line - 1)
            if selfClosed {
                blocks.append(make(.mathBlock(closed: true), line, line))
            } else {
                open = .math(fromLine: line)
            }
            return line + 1

        case .quote(let callout):
            if case .quote(let from, let existing) = open {
                open = .quote(fromLine: from, callout: existing)
            } else {
                closeOpen(through: line - 1)
                open = .quote(fromLine: line, callout: callout)
            }
            return line + 1

        case .listMarker(let listInfo):
            closeOpen(through: line - 1)
            open = .list(fromLine: line, info: listInfo)
            return line + 1

        case .thematicBreak:
            closeOpen(through: line - 1)
            blocks.append(make(.thematicBreak, line, line))
            return line + 1

        case .setextUnderline(let level):
            if case .paragraph(let from) = open {
                blocks.append(make(.heading(level: level, setext: true), from, line))
                open = .none
                return line + 1
            }
            // No open paragraph: `---…` is a break; `=` runs are just text.
            if level == 2, info.indent <= 3 {
                // A bare `-`/`--` isn't a break; three or more is.
                let content = lines.contentRange(line, in: text)
                if content.length - info.indent >= 3 {
                    closeOpen(through: line - 1)
                    blocks.append(make(.thematicBreak, line, line))
                    return line + 1
                }
            }
            fallthrough

        case .text:
            switch open {
            case .paragraph:
                break                               // continue the paragraph
            case .list(let from, let listInfo):
                // Indented lines continue the item; anything else ends it.
                if info.indent > listInfo.indent {
                    open = .list(fromLine: from, info: listInfo)
                } else {
                    closeOpen(through: line - 1)
                    open = .paragraph(fromLine: line)
                }
            case .table:
                closeOpen(through: line - 1)
                open = .paragraph(fromLine: line)
            default:
                closeOpen(through: line - 1)
                open = .paragraph(fromLine: line)
            }
            return line + 1

        case .pipeRow(let isDelimiterRow):
            switch open {
            case .table(let from, true):
                open = .table(fromLine: from, sawDelimiter: true)   // data row
            case .paragraph(let from):
                if isDelimiterRow, line == lastParagraphLine(from: from, current: line) {
                    // Previous paragraph line + this delimiter row = table.
                    // (Editor-grade: the header is the immediately
                    // preceding line; earlier lines stay a paragraph.)
                    if line - 1 > from {
                        blocks.append(make(.paragraph, from, line - 2))
                    }
                    open = .table(fromLine: line - 1, sawDelimiter: true)
                } else {
                    break                            // stays paragraph text
                }
            case .list(let from, let listInfo):
                if info.indent > listInfo.indent { break }  // continuation
                closeOpen(through: line - 1)
                open = .paragraph(fromLine: line)
            default:
                closeOpen(through: line - 1)
                open = .paragraph(fromLine: line)   // pipe text; may become
                                                    // a table if a delimiter
                                                    // row follows
            }
            return line + 1
        }
    }

    private func lastParagraphLine(from: Int, current: Int) -> Int { current }

    /// Close whatever block is open, ending at `line` (inclusive).
    private mutating func closeOpen(through line: Int) {
        switch open {
        case .none:
            break
        case .paragraph(let from):
            blocks.append(make(.paragraph, from, line))
        case .fence(let from, _, let count, let info):
            _ = count
            blocks.append(make(.fencedCode(info: info, closed: false), from, line))
        case .math(let from):
            blocks.append(make(.mathBlock(closed: false), from, line))
        case .quote(let from, let callout):
            blocks.append(make(.blockquote(callout: callout), from, line))
        case .list(let from, let info):
            blocks.append(make(.listItem(info), from, line))
        case .table(let from, let sawDelimiter):
            blocks.append(make(sawDelimiter ? .table : .paragraph, from, line))
        case .blank(let from):
            blocks.append(make(.blank, from, line))
        }
        open = .none
    }

    private func make(_ kind: BlockKind, _ fromLine: Int, _ toLine: Int) -> Block {
        let start = lines.lineRange(fromLine).location
        let endRange = lines.lineRange(toLine)
        let end = endRange.location + endRange.length
        return Block(kind: kind, range: NSRange(location: start, length: end - start),
                     firstLine: fromLine, lineCount: toLine - fromLine + 1)
    }

    mutating func emit(kind: BlockKind, fromLine: Int, throughLine: Int) {
        blocks.append(make(kind, fromLine, throughLine))
    }

    private func lineContainsMathClose(_ line: Int) -> Bool {
        let r = lines.contentRange(line, in: text)
        var i = r.location
        let end = r.location + r.length
        while i + 1 < end + 1 {
            if i + 1 <= end - 1, text.character(at: i) == 0x24, text.character(at: i + 1) == 0x24 {
                return true
            }
            if i >= end { break }
            i += 1
        }
        return false
    }

    mutating func finish() -> [Block] {
        closeOpen(through: lastLine)
        return blocks
    }
}

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
            if let close, holdsAProperty(text, lines: lines, after: 0, before: close) {
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

    /// Does the text between two `---` fences hold at least one YAML mapping
    /// entry — a `key:` line?
    ///
    /// Two `---` lines near the top of a note are not enough to make what is
    /// between them front matter, and reading them that way loses the reader's
    /// content: front matter *folds*, so a note that opens with a horizontal
    /// rule and carries another one a few paragraphs down had its whole first
    /// section concealed and its body appear to start at the second rule. The
    /// closing fence was hunted for 200 lines away, so the amount that could
    /// vanish had no practical limit.
    ///
    /// A property is the thing front matter exists to carry — it is what the
    /// Properties panel reads, and `FrontMatter.applying` deletes the block
    /// outright when the last one goes, so a block holding none is a block
    /// HelloNotes itself would not have written. Requiring one is also what
    /// makes `---⏎---` and `---⏎Foo⏎---` read the way every other Markdown
    /// tool reads them: a thematic break, and a thematic break followed by a
    /// setext heading (GFM spec examples 68 and 66).
    ///
    /// Deliberately the *only* extra condition. Demanding that every interior
    /// line look like YAML sounds stricter and is worse: a `#` line is a legal
    /// YAML comment *and* the commonest way a note's first heading is written,
    /// so the rule that rejects one rejects the other, and prose sitting under
    /// a real `title:` would stop the block being front matter at all. One
    /// mapping entry is the signal; the rest of the block is the user's.
    static func holdsAProperty(_ text: NSString, lines: LineIndex,
                               after openFence: Int, before closeFence: Int) -> Bool {
        guard closeFence > openFence + 1 else { return false }
        for i in (openFence + 1)..<closeFence where isMappingEntry(text, lineRange: lines.lineRange(i)) {
            return true
        }
        return false
    }

    /// `key:` or `key: value` — YAML's mapping entry, and nothing else.
    ///
    /// The colon has to end the line or be followed by a space: without that,
    /// `12:30 standup` and a bare URL are both mapping entries, and a note
    /// opening with a rule over a diary line would fold itself away again.
    /// A leading `#` is a YAML *comment* and a leading `-` a sequence item;
    /// neither can be the entry that proves the block is a mapping, and `#` is
    /// how `## Meeting notes` starts.
    static func isMappingEntry(_ text: NSString, lineRange: NSRange) -> Bool {
        var i = lineRange.location
        var end = lineRange.location + lineRange.length
        if end > i && text.character(at: end - 1) == 0x0A { end -= 1 }
        if end > i && text.character(at: end - 1) == 0x0D { end -= 1 }
        while i < end, text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1 }
        guard i < end else { return false }
        let first = text.character(at: i)
        guard first != 0x23, first != 0x2D else { return false }   // `#` comment, `-` item
        let keyStart = i
        while i < end, text.character(at: i) != 0x3A { i += 1 }
        guard i < end, i > keyStart else { return false }          // a colon, with a key before it
        let afterColon = i + 1
        return afterColon == end
            || text.character(at: afterColon) == 0x20
            || text.character(at: afterColon) == 0x09
    }

    /// A line that is exactly `---` (with up to 3 leading spaces, trailing
    /// whitespace allowed) — the front matter fence.
    static func isDashFence(_ text: NSString, lineRange: NSRange) -> Bool {
        var i = lineRange.location
        var end = lineRange.location + lineRange.length
        if end > i && text.character(at: end - 1) == 0x0A { end -= 1 }
        // …and the CR of a CRLF pair, or the trailing-whitespace check below
        // rejects a perfectly good `---` fence and front matter never folds.
        if end > i && text.character(at: end - 1) == 0x0D { end -= 1 }
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
        /// Opens a raw HTML block; carries CommonMark's start-condition
        /// number (1…7), which also selects the end condition.
        case htmlOpen(condition: Int)
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

    /// Does this line meet the end condition for an open HTML block of
    /// `condition`? Reads through the same reusable buffer as `classify`.
    mutating func htmlBlockEnds(lineRange: NSRange, condition: Int) -> Bool {
        let len = lineRange.length
        if buffer.count < len { buffer = [unichar](repeating: 0, count: max(len, 256)) }
        if len > 0 {
            buffer.withUnsafeMutableBufferPointer { buf in
                text.getCharacters(buf.baseAddress!, range: lineRange)
            }
        }
        return Self.htmlBlockEnds(buffer, count: len, condition: condition)
    }

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

    static func classify(_ b: [unichar], count rawCount: Int) -> LineInfo {
        // `contentRange` strips the `\n` but not the `\r`, so a CRLF file hands
        // every classifier below a trailing carriage return. They all scan to
        // `count`, so that CR made `===`, `---`, `***` and `___` fail to match:
        // setext headings and thematic breaks silently parsed as paragraphs in
        // any CRLF document. (The fence case trimmed 0x0D itself, which is why
        // fenced code was the one construct that worked.)
        var count = rawCount
        if count > 0, b[count - 1] == 0x0D { count -= 1 }

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
                    // A backtick fence's info string may not contain a
                    // backtick — otherwise ``` ``` ``` on one line would open a
                    // block that the same line closes. CommonMark makes it an
                    // ordinary paragraph holding a code span, and the editor
                    // opened a fence that swallowed everything after it.
                    if c == 0x60, info.contains("`") { break }
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
            case 0x3C: // '<'
                if let condition = htmlBlockStart(b, from: i, count: count) {
                    return LineInfo(kind: .htmlOpen(condition: condition), indent: indent)
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
                        // Trailing whitespace does not stop a line being a
                        // setext underline — `Foo` over `   ----      ` is an
                        // h2. Counting those spaces as "not pure" sent the line
                        // to the thematic-break branch instead, so a heading
                        // someone had lined up with spaces became a paragraph
                        // and a rule.
                        var last = count
                        while last > i, b[last - 1] == 0x20 || b[last - 1] == 0x09 { last -= 1 }
                        var pure = true
                        for k in i..<last where b[k] != 0x2D { pure = false; break }
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
            // A tab separates a marker from its content just as a space does —
            // `-\tfoo` is a list item to CommonMark, and reading it as a
            // paragraph put a whole document's worth of tab-indented lists in
            // the wrong shape.
            if i + 1 == count || b[i+1] == 0x20 || b[i+1] == 0x09 {
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

    // MARK: - Raw HTML blocks

    /// Tags that open a *literal* block (condition 1): everything up to the
    /// matching close tag is raw, including blank lines.
    private static let rawTextTags: Set<String> = ["script", "pre", "style", "textarea"]

    /// CommonMark's block-level tag list (condition 6). A line starting with
    /// one of these — open or closing — begins an HTML block that runs to the
    /// next blank line.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
        "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search",
        "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
        "title", "tr", "track", "ul",
    ]

    /// Which of CommonMark's seven HTML-block start conditions this line meets
    /// (§4.6), or nil for none. `i` is the index of the `<`.
    ///
    /// The number matters beyond classification: it is what says where the
    /// block *ends*. 1–5 each close on their own end string and may contain
    /// blank lines; 6 and 7 close at the next blank line.
    static func htmlBlockStart(_ b: [unichar], from i: Int, count: Int) -> Int? {
        guard i + 1 < count else { return nil }

        if hasPrefix(b, at: i, count: count, "<!--") { return 2 }
        if b[i + 1] == 0x3F { return 3 }                               // `<?`
        if hasPrefix(b, at: i, count: count, "<![CDATA[") { return 5 }
        if b[i + 1] == 0x21 {                                          // `<!`
            guard i + 2 < count, isASCIILetter(b[i + 2]) else { return nil }
            return 4
        }

        var j = i + 1
        let closing = b[j] == 0x2F                                     // `</`
        if closing { j += 1 }
        var name: [unichar] = []
        while j < count, isTagNameChar(b[j]) { name.append(b[j]); j += 1 }
        guard !name.isEmpty else { return nil }
        let tag = String(utf16CodeUnits: name, count: name.count).lowercased()

        // 1 — only the opening tag counts; `</pre>` alone does not open one.
        if !closing, rawTextTags.contains(tag),
           j == count || b[j] == 0x20 || b[j] == 0x09 || b[j] == 0x3E {
            return 1
        }
        // 6 — a known block tag followed by whitespace, `>`, `/>` or EOL.
        if blockTags.contains(tag) {
            if j == count || b[j] == 0x20 || b[j] == 0x09 || b[j] == 0x3E { return 6 }
            if b[j] == 0x2F, j + 1 < count, b[j + 1] == 0x3E { return 6 }
        }
        // 7 — any *complete* tag, standing alone on its line.
        if isCompleteTagAlone(b, from: i, count: count) { return 7 }
        return nil
    }

    /// One well-formed open or closing tag starting at `i`, followed by nothing
    /// but whitespace. Attribute values may be single-quoted, double-quoted or
    /// bare, and a bare value may not contain the quote characters or `<>=`.
    private static func isCompleteTagAlone(_ b: [unichar], from i: Int, count: Int) -> Bool {
        var j = i + 1
        let closing = j < count && b[j] == 0x2F
        if closing { j += 1 }
        guard j < count, isASCIILetter(b[j]) else { return false }
        while j < count, isTagNameChar(b[j]) { j += 1 }

        if closing {
            while j < count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
            guard j < count, b[j] == 0x3E else { return false }
            return isBlankTo(b, from: j + 1, count: count)
        }

        while true {
            var sawSpace = false
            while j < count, b[j] == 0x20 || b[j] == 0x09 { j += 1; sawSpace = true }
            if j < count, b[j] == 0x2F, j + 1 < count, b[j + 1] == 0x3E {
                return isBlankTo(b, from: j + 2, count: count)
            }
            if j < count, b[j] == 0x3E {
                return isBlankTo(b, from: j + 1, count: count)
            }
            // Another attribute has to be separated from what precedes it.
            guard sawSpace, j < count, isAttributeNameStart(b[j]) else { return false }
            while j < count, isAttributeNameChar(b[j]) { j += 1 }
            while j < count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
            guard j < count, b[j] == 0x3D else { continue }            // no value
            j += 1
            while j < count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
            guard j < count else { return false }
            if b[j] == 0x22 || b[j] == 0x27 {                          // quoted
                let quote = b[j]; j += 1
                while j < count, b[j] != quote { j += 1 }
                guard j < count else { return false }
                j += 1
            } else {                                                   // bare
                let start = j
                while j < count, !isBareValueTerminator(b[j]) { j += 1 }
                guard j > start else { return false }
            }
        }
    }

    /// The end condition for an open HTML block of this type, on one line.
    /// Types 6 and 7 end at a blank line and are handled by the block builder,
    /// so they never reach here.
    static func htmlBlockEnds(_ b: [unichar], count: Int, condition: Int) -> Bool {
        switch condition {
        case 1:
            return rawTextTags.contains { contains(b, count: count, "</\($0)>") }
        case 2: return contains(b, count: count, "-->")
        case 3: return contains(b, count: count, "?>")
        case 4: return contains(b, count: count, ">")
        case 5: return contains(b, count: count, "]]>")
        default: return false
        }
    }

    // MARK: Character predicates

    private static func isASCIILetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isTagNameChar(_ c: unichar) -> Bool {
        isASCIILetter(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D      // `-`
    }

    private static func isAttributeNameStart(_ c: unichar) -> Bool {
        isASCIILetter(c) || c == 0x5F || c == 0x3A                     // `_` `:`
    }

    private static func isAttributeNameChar(_ c: unichar) -> Bool {
        isAttributeNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2E || c == 0x2D
    }

    private static func isBareValueTerminator(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x22 || c == 0x27 || c == 0x3D
            || c == 0x3C || c == 0x3E || c == 0x60
    }

    private static func isBlankTo(_ b: [unichar], from: Int, count: Int) -> Bool {
        var j = from
        while j < count, b[j] == 0x20 || b[j] == 0x09 || b[j] == 0x0D { j += 1 }
        return j >= count
    }

    /// ASCII, case-insensitive prefix match at `at`.
    private static func hasPrefix(_ b: [unichar], at: Int, count: Int, _ s: String) -> Bool {
        let want = Array(s.utf16)
        guard at + want.count <= count else { return false }
        for k in 0..<want.count where lowered(b[at + k]) != lowered(want[k]) { return false }
        return true
    }

    /// ASCII, case-insensitive substring search.
    private static func contains(_ b: [unichar], count: Int, _ s: String) -> Bool {
        let want = Array(s.utf16)
        guard want.count <= count else { return false }
        for start in 0...(count - want.count) {
            var k = 0
            while k < want.count, lowered(b[start + k]) == lowered(want[k]) { k += 1 }
            if k == want.count { return true }
        }
        return false
    }

    private static func lowered(_ c: unichar) -> unichar {
        (c >= 0x41 && c <= 0x5A) ? c + 32 : c
    }

    private static func listInfo(_ b: [unichar], count: Int, indent: Int, markerLength: Int, ordered: Bool) -> ListInfo {
        // CommonMark's content column: the marker, then the spaces that follow
        // it — but only one to four of them. Five or more means the content is
        // an indented code block starting one space past the marker, and a
        // marker with nothing after it takes one space too.
        //
        // Skipping exactly one space put the content column two short on every
        // `-    item`, which is what decides where a continuation line belongs
        // and where code begins inside the item.
        var content = indent + markerLength
        var spaces = 0
        while content < count, b[content] == 0x20, spaces < 5 { content += 1; spaces += 1 }
        // Five or more spaces, none at all, or nothing but spaces to the end of
        // the line: the content column is one past the marker. That last case
        // is CommonMark's "item starting with a blank line" — `-   ` on its own
        // sets the column from the marker, not from however many spaces the
        // writer happened to leave before pressing return.
        if spaces == 0 || spaces >= 5 || content >= count { content = indent + markerLength + 1 }
        // The content *column*, with tabs expanded. A tab straight after the
        // marker counts as one space of padding, which is what puts the code in
        // `-\t\tfoo` four columns past the item's content and makes it a code
        // block rather than a word.
        //
        // Measured here, **before** the checkbox below is stepped over, and
        // that ordering is the whole point. A checkbox is plain characters —
        // which is exactly why the content column stops before it. The column
        // is where the item's content *begins*, and `[x] ` is content:
        // CommonMark opens the item after `- ` and the task extension eats the
        // checkbox out of the paragraph that starts there. Measured after, the
        // column landed on 3 rather than 2, so a sub-list needed three spaces
        // of indent to count as nested and the two everybody writes read as a
        // *sibling* — `li + li { margin-top: .25em }` where the page puts
        // `ul ul { margin-top: 0 }`. 4pt per nested task item, and a checklist
        // is mostly nested task items. `contentOffset` still points past the
        // checkbox, because that is where the text is drawn.
        var column = indent + markerLength
        var k = indent + markerLength
        if k < count, b[k] == 0x09 {
            column += 1
        } else {
            while k < content { if b[k] == 0x20 { column += 1 }; k += 1 }
        }
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
        return ListInfo(indent: indent, markerLength: markerLength, isOrdered: ordered,
                        task: task, contentOffset: content, contentColumn: column)
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

    /// The number an ordered marker starts with, read from the line itself —
    /// `ListInfo` keeps the marker's *width*, not its value.
    private func orderedStart(_ line: Int) -> Int? {
        let content = lines.contentRange(line, in: text)
        var i = content.location
        let end = content.location + content.length
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        var value = 0, digits = 0
        while i < end, text.character(at: i) >= 0x30, text.character(at: i) <= 0x39, digits < 9 {
            value = value * 10 + Int(text.character(at: i)) - 0x30
            digits += 1
            i += 1
        }
        return digits > 0 ? value : nil
    }

    /// The list item the parse most recently closed, if only blank lines have
    /// happened since. A marker line always ends the open list (a marker of its
    /// own starts a nested list), so by the time one is classified `open` is
    /// `.blank` and the item it has to be measured against is no longer there.
    private func mostRecentItem() -> ListInfo? {
        for block in blocks.reversed() {
            switch block.kind {
            case .blank: continue
            case .listItem(let info): return info
            default: return nil
            }
        }
        return nil
    }


    private enum Open {
        case none
        case paragraph(fromLine: Int)
        case fence(fromLine: Int, marker: unichar, count: Int, info: String)
        case math(fromLine: Int)
        case quote(fromLine: Int, callout: String?)
        case list(fromLine: Int, info: ListInfo)
        /// A fence opened on an item's **marker line** — `1. ``` `. It belongs
        /// to the item, exactly as indented code on that line does, so the
        /// item stays open across it. Without this the opening delimiter was
        /// swallowed as item text and the *closing* one read as a fresh,
        /// unclosed fence: everything below `1. ``` ` in the note came out as
        /// code, to the end of the document.
        case listFence(fromLine: Int, info: ListInfo, marker: unichar, count: Int)
        case table(fromLine: Int, sawDelimiter: Bool)
        case indentedCode(fromLine: Int)
        case blank(fromLine: Int)
        case html(fromLine: Int, condition: Int)
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
        case .listFence(let from, let listInfo, let marker, let count):
            // The closing delimiter ends the fence and hands the item back,
            // so a paragraph after it is still the item's.
            if case .fenceDelimiter(let m, let n, let closeInfo) = info.kind,
               m == marker, n >= count, closeInfo.isEmpty {
                open = .list(fromLine: from, info: listInfo)
            }
            return line + 1
        case .math(let from):
            if lineContainsMathClose(line) {
                blocks.append(make(.mathBlock(closed: true), from, line))
                open = .none
            }
            return line + 1
        case .html(let from, let condition):
            // Conditions 1–5 run to their own end string and may contain blank
            // lines; 6 and 7 stop at the first blank line, which belongs to
            // whatever follows rather than to the block.
            if condition >= 6 {
                if case .blank = info.kind {
                    blocks.append(make(.htmlBlock(condition: condition, closed: true), from, line - 1))
                    open = .blank(fromLine: line)
                    return line + 1
                }
            } else if cursor.htmlBlockEnds(lineRange: lines.lineRange(line), condition: condition) {
                blocks.append(make(.htmlBlock(condition: condition, closed: true), from, line))
                open = .none
            }
            return line + 1
        default:
            break
        }

        switch info.kind {
        case .blank:
            // A blank line stays inside an open indented code block (chunks may
            // be blank-separated); it ends anything else.
            if case .indentedCode = open { return line + 1 }
            // …and it stays inside an open list item, as long as what follows
            // the blank run is indented to the item's own content column. That
            // is CommonMark's rule, and it is what makes a list *loose*:
            //
            //     - one
            //
            //       two
            //
            // is one item holding two paragraphs, not an item, a gap and a
            // stray paragraph. Closing the item here cost the editor a whole
            // family of list examples — every one of them short by the two
            // paragraph margins a loose item's `<p>` children carry.
            if case .list(let from, let listInfo) = open,
               // "A list item can begin with at most one blank line." An item
               // whose marker line already carries nothing has used its one up,
               // so a blank line after it ends the item — `-` / blank / `  foo`
               // is an empty item and a paragraph, not an item holding `foo`.
               !(from == line - 1 && !contentPastMarker(from, listInfo)),
               listContinues(after: line, contentColumn: listInfo.contentColumn, cursor: &cursor) {
                open = .list(fromLine: from, info: listInfo)
                return line + 1
            }
            // Extend an open blank run rather than closing and reopening it.
            // The test used to sit *after* `closeOpen`, which resets `open` to
            // `.none` — so it never matched and every blank line became its own
            // one-line block instead of one run.
            if case .blank = open { return line + 1 }
            closeOpen(through: line - 1)
            open = .blank(fromLine: line)
            return line + 1

        case .atxHeading(let level):
            closeOpen(through: line - 1)
            blocks.append(make(.heading(level: level, setext: false), line, line))
            return line + 1

        case .fenceDelimiter(let marker, let count, let fenceInfo):
            // A fence indented to the open item's own content column is a block
            // *inside* the item, exactly as a fence on the marker line is —
            // `-` / `  ``` ` / `  bar` / `  ``` ` is one item holding a code
            // block. Closing the item here (which is what every fence used to
            // do, whatever its indent) ended the list at the opening delimiter
            // and made the code a sibling of it, so the `<li>` the page draws
            // around the box was a marker line on its own and the box below it.
            //
            // `.listFence` carries the item's own start line, so the closing
            // delimiter hands the item back and anything after it is still the
            // item's content.
            if case .list(let from, let listInfo) = open,
               info.indent >= listInfo.contentColumn {
                open = .listFence(fromLine: from, info: listInfo, marker: marker, count: count)
                return line + 1
            }
            closeOpen(through: line - 1)
            open = .fence(fromLine: line, marker: marker, count: count, info: fenceInfo)
            return line + 1

        case .htmlOpen(let condition):
            // Condition 7 is the only one that cannot interrupt a paragraph —
            // a lone `<span>` on the second line of a paragraph is part of the
            // paragraph, not the start of a block.
            if condition == 7, case .paragraph = open { return line + 1 }
            closeOpen(through: line - 1)
            // A one-line block whose end condition is already met on its own
            // line (`<!-- comment -->`, `<div>text</div>`) closes immediately.
            if condition <= 5,
               cursor.htmlBlockEnds(lineRange: lines.lineRange(line), condition: condition) {
                blocks.append(make(.htmlBlock(condition: condition, closed: true), line, line))
                open = .none
            } else {
                open = .html(fromLine: line, condition: condition)
            }
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
            // Indented past a code block's column, below an open quote
            // paragraph, this is a lazy continuation line — `> foo` then
            // `    - bar` is one quoted paragraph, and the dash is text.
            if case .quote(let from, let callout) = open, info.indent >= 4,
               quoteLineHasContent(line - 1) {
                open = .quote(fromLine: from, callout: callout)
                return line + 1
            }
            // The same lazy continuation below an open *list item*. A line
            // indented four or more, but short of the item's own content
            // column, is not inside the item — it dedents to the document,
            // where four columns means indented code, and indented code cannot
            // interrupt a paragraph. So it is the item's paragraph, continued,
            // and the dash is text: `   - d` then `    - e` is one item
            // reading "d ⏎ - e", not two. (At or past the content column the
            // line *is* inside the item, and a marker there opens a nested
            // list, which is handled below.)
            if case .list(let from, let listInfo) = open,
               info.indent >= 4, info.indent < listInfo.contentColumn,
               lineHasContent(line - 1) {
                open = .list(fromLine: from, info: listInfo)
                return line + 1
            }
            // With no paragraph open, the same line is **indented code**. The
            // list closed at the blank, and four columns at the document's
            // level is a code block: `1. a` / blank / `  2. b` / blank /
            // `    3. c` is two items and a `<pre>`, not three items. Read as a
            // marker it was a third item 40pt short of the code box the page
            // draws.
            //
            // The column to be short *of* is the enclosing item's; with no
            // item anywhere above there is nothing to be inside, and four
            // columns is simply code. Requiring `mostRecentItem()` to exist
            // read the whole rule backwards at the document's own level, so
            // `    1.  A paragraph` opening a note — a `<pre>` to every
            // renderer — came out as a list, and every line under it as the
            // list's prose.
            if info.indent >= 4, !lineHasContent(line - 1),
               info.indent < (mostRecentItem()?.contentColumn ?? Int.max) {
                // Already inside a code block (a blank line does not end one):
                // this line is more of the same box, not a second one paying
                // for its own padding.
                if case .indentedCode(let from) = open {
                    open = .indentedCode(fromLine: from)
                } else {
                    closeOpen(through: line - 1)
                    open = .indentedCode(fromLine: line)
                }
                return line + 1
            }
            // "In order for a list to interrupt a paragraph, it must start with
            // 1." Prose that happens to wrap onto a line beginning `14. ` is
            // one paragraph, not a paragraph and a list — read as a marker it
            // broke the sentence in two and put a block margin through it.
            if case .paragraph = open, listInfo.isOrdered, orderedStart(line) != 1 {
                return line + 1
            }
            // An *empty* item cannot interrupt a paragraph: `*foo bar` then a
            // lone `*` is one paragraph to CommonMark, not a paragraph and a
            // list. Read as a marker it broke the paragraph in two and put a
            // block margin through the middle of a sentence.
            if case .paragraph = open,
               trimmedLength(lines.contentRange(line, in: text)) <= listInfo.contentOffset {
                return line + 1
            }
            closeOpen(through: line - 1)
            // Does the item's own content open a fence? Classify what follows
            // the marker, which is the only place that can be read from.
            let content = lines.contentRange(line, in: text)
            if listInfo.contentOffset < content.length {
                let after = NSRange(location: content.location + listInfo.contentOffset,
                                    length: content.length - listInfo.contentOffset)
                if case .fenceDelimiter(let m, let n, _) = cursor.classify(lineRange: after).kind {
                    open = .listFence(fromLine: line, info: listInfo, marker: m, count: n)
                    return line + 1
                }
            }
            open = .list(fromLine: line, info: listInfo)
            return line + 1

        case .thematicBreak:
            closeOpen(through: line - 1)
            blocks.append(make(.thematicBreak, line, line))
            return line + 1

        case .setextUnderline(let level):
            // Not over reference definitions. `[foo]: /url` then `===` is a
            // consumed definition followed by a paragraph — the definition is
            // gone before setext is considered, so there is no heading text for
            // the underline to belong to. The editor made the whole thing an
            // h1, which is a definition rendered as a banner.
            if case .paragraph(let from) = open, !allReferenceDefinitions(from, through: line - 1) {
                blocks.append(make(.heading(level: level, setext: true), from, line))
                open = .none
                return line + 1
            }
            // Inside a list item, indented to the item's own content column and
            // with text on the line above, it underlines *that* text: the spec
            // gives a setext heading precedence over a thematic break when a
            // line of dashes could be either. Read as a break it ended the list
            // and put a rule where the rendered page draws a heading.
            if case .list(let from, let listInfo) = open,
               info.indent >= listInfo.contentOffset,
               lineHasContent(line - 1) {
                open = .list(fromLine: from, info: listInfo)
                return line + 1
            }
            // No open paragraph: `---…` is a break; `=` runs are just text.
            if level == 2, info.indent <= 3 {
                // A bare `-`/`--` isn't a break; three or more is — counted in
                // *dashes*. Counting characters made `-   ` a thematic break on
                // the strength of its trailing spaces, when it is an empty list
                // item.
                let content = lines.contentRange(line, in: text)
                var dashes = 0
                for k in content.location..<(content.location + content.length)
                where text.character(at: k) == 0x2D { dashes += 1 }
                if dashes >= 3 {
                    closeOpen(through: line - 1)
                    blocks.append(make(.thematicBreak, line, line))
                    return line + 1
                }
                // A single `-` with no paragraph above it is an **empty list
                // item**, not a line of text — `- foo` / `-` / `- bar` is a
                // three-item list to cmark. Read as text it split the list in
                // two and put a block margin either side of the gap, where the
                // rendered page has an item and a list that never broke.
                //
                // The classifier cannot make this call: after a paragraph the
                // same character is a setext underline, which is why it arrives
                // here as one.
                if trimmedLength(content) - info.indent == 1 {
                    // Content column: the marker plus one, which is what an
                    // item that starts with a blank line gets.
                    let empty = ListInfo(indent: info.indent, markerLength: 1,
                                         isOrdered: false, task: nil,
                                         contentOffset: info.indent + 2,
                                         contentColumn: info.indent + 2)
                    closeOpen(through: line - 1)
                    open = .list(fromLine: line, info: empty)
                    return line + 1
                }
            }
            fallthrough

        case .text:
            switch open {
            case .paragraph:
                break                               // continue the paragraph
                                                    // (indented code can't interrupt it)
            case .quote(let from, let callout):
                // Lazy continuation: a paragraph inside a blockquote runs on to
                // a line carrying no `>` of its own. `> bar` / `baz` is one
                // quoted paragraph, not a quote and a paragraph — which is what
                // the editor made of it, complete with a block gap between them
                // that the rendered page does not have.
                //
                // Only when there is a paragraph to continue: after a `>` on
                // its own the quote's paragraph has ended, and the next
                // unprefixed line starts something new.
                // …and only a *paragraph* runs on. A fence swallows nothing:
                // `> ``` ` then an unquoted `foo` is a quote holding an empty
                // code block and then a paragraph, not a two-line quote. Read
                // as continuation the unquoted text joined the quote, and
                // anything below it went with it.
                if quoteLineHasContent(line - 1),
                   !quoteHasOpenFence(from: from, through: line - 1, cursor: &cursor) {
                    open = .quote(fromLine: from, callout: callout)
                } else {
                    closeOpen(through: line - 1)
                    open = info.indent >= 4 ? .indentedCode(fromLine: line) : .paragraph(fromLine: line)
                }
            case .indentedCode(let from):
                if info.indent >= 4 {
                    open = .indentedCode(fromLine: from)   // continue the code block
                } else {
                    closeOpen(through: line - 1)
                    open = .paragraph(fromLine: line)
                }
            case .list(let from, let listInfo):
                // Indented lines continue the item; anything else ends it —
                // except a lazy continuation, which the quote branch above has
                // always had and this one never did. A paragraph inside a list
                // item runs on to a line carrying none of the item's indent,
                // exactly as a paragraph inside a blockquote runs on to a line
                // carrying no `>`: `  1.  A paragraph` over an unindented
                // `with two lines.` is one paragraph in one item. Ended here,
                // it came out as an item and a separate paragraph with a 16pt
                // block margin through the middle of a sentence.
                //
                // Only a *paragraph* runs on, and only plain text continues
                // it: a heading, a fence, a rule or an indented-code line
                // inside the item all close the paragraph, and the underline
                // spellings reach this case by fallthrough from
                // `.setextUnderline`, so the line's own kind is asked too.
                if info.indent > listInfo.indent {
                    open = .list(fromLine: from, info: listInfo)
                } else if case .text = info.kind,
                          itemParagraphIsOpen(at: line - 1, itemStart: from,
                                              info: listInfo, cursor: &cursor) {
                    open = .list(fromLine: from, info: listInfo)
                } else {
                    closeOpen(through: line - 1)
                    open = info.indent >= 4 ? .indentedCode(fromLine: line) : .paragraph(fromLine: line)
                }
            case .table(let from, true):
                // A table row does not have to contain a pipe. GFM breaks a
                // table "at the first empty line, or beginning of another
                // block-level structure" — and a line of prose is neither, so
                // `| a | b |` / `| - | - |` / `text` is a three-row table whose
                // last row holds `text` in its first cell. Closed here, the
                // editor drew a two-row grid and a paragraph while the page
                // drew a three-row grid: the same note, one row and one block
                // margin apart.
                open = .table(fromLine: from, sawDelimiter: true)
            default:   // .none, .blank, an unconfirmed table
                closeOpen(through: line - 1)
                // 4-space / tab indent with no paragraph to continue = code.
                open = info.indent >= 4 ? .indentedCode(fromLine: line) : .paragraph(fromLine: line)
            }
            return line + 1

        case .pipeRow(let isDelimiterRow):
            switch open {
            case .table(let from, true):
                open = .table(fromLine: from, sawDelimiter: true)   // data row
            case .paragraph(let from):
                // …and only when the delimiter row has as many cells as the
                // header. GFM: "If not, a table will not be recognized" — so
                // `| abc | def |` over `| --- |` is a paragraph of three lines,
                // and an editor that drew a grid there was showing a document
                // the page never renders.
                if isDelimiterRow, line == lastParagraphLine(from: from, current: line),
                   tableCellCount(line) == tableCellCount(line - 1) {
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
                if info.indent > listInfo.indent {
                    // A **table** opening inside the item, which is not the
                    // same thing as more of the item's text.
                    //
                    // GFM confirms a table only on its delimiter row, so the
                    // header is the line above and the item has to be closed
                    // *before* it — exactly the retroactive split the paragraph
                    // case above makes at the top level. Without it the pipes
                    // stayed item content: the editor drew four lines of
                    // `| a | b |` where the page drew a grid, which is 3pt on a
                    // two-row table and 29 on a four-row one, and a table under
                    // a numbered step is how every set of instructions is
                    // written. Nothing in the specification corpus nests one,
                    // so nothing said so.
                    //
                    // Emitted as its own block rather than styled in place,
                    // because a table is a *picture* here — `applyNestedCode`
                    // can paint a code box over the item's own lines and there
                    // is no equivalent for a grid. A block of its own is also
                    // how a `>` quote inside an item has always been handled,
                    // and `gapBetween` already knows that a block indented to
                    // the item's content column carries no margin above it.
                    if isDelimiterRow, line - 1 > from,
                       tableCellCount(line) == tableCellCount(line - 1),
                       itemTableHeader(at: line - 1, itemStart: from,
                                       info: listInfo, cursor: &cursor) {
                        closeOpen(through: line - 2)
                        open = .table(fromLine: line - 1, sawDelimiter: true)
                    }
                    break                                   // continuation
                }
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

    /// How many cells `line` splits into, by GFM's rule — an unescaped pipe
    /// divides, the outer ones only bound. Read through `GFMTableLayout` so
    /// the count that decides whether this *is* a table and the split that
    /// decides what is in it can never be two different opinions.
    private func tableCellCount(_ line: Int) -> Int {
        let content = lines.contentRange(line, in: text)
        guard content.length > 0 else { return 0 }
        var buffer = [unichar](repeating: 0, count: content.length)
        text.getCharacters(&buffer, range: content)
        return GFMTableLayout.cellCount(buffer, from: 0, count: buffer.count)
    }

    /// Is every line from `from` through `to` a link reference definition?
    private func allReferenceDefinitions(_ from: Int, through to: Int) -> Bool {
        guard from <= to else { return false }
        for line in from...to
        where !ReferenceDefinition.matches(text, contentRange: lines.contentRange(line, in: text)) {
            return false
        }
        return true
    }

    /// Does the item's marker line carry anything after the marker?
    private func contentPastMarker(_ lineNumber: Int, _ info: ListInfo) -> Bool {
        guard lineNumber >= 0, lineNumber < lines.lineCount else { return false }
        let content = lines.contentRange(lineNumber, in: text)
        var i = min(content.location + info.contentOffset, content.location + content.length)
        let end = content.location + content.length
        while i < end {
            let c = text.character(at: i)
            if c != 0x20 && c != 0x09 && c != 0x0D { return true }
            i += 1
        }
        return false
    }

    /// Does the line carry anything but whitespace?
    private func lineHasContent(_ lineNumber: Int) -> Bool {
        guard lineNumber >= 0, lineNumber < lines.lineCount else { return false }
        let content = lines.contentRange(lineNumber, in: text)
        for i in content.location..<(content.location + content.length) {
            let c = text.character(at: i)
            if c != 0x20 && c != 0x09 && c != 0x0D { return true }
        }
        return false
    }

    /// The line's length with trailing spaces, tabs and a carriage return
    /// discounted — what the writer actually typed.
    private func trimmedLength(_ content: NSRange) -> Int {
        var end = content.location + content.length
        while end > content.location {
            let c = text.character(at: end - 1)
            if c == 0x20 || c == 0x09 || c == 0x0D { end -= 1 } else { break }
        }
        return end - content.location
    }

    /// Does the quote line at `lineNumber` leave a *paragraph* open for the
    /// next line to continue lazily?
    ///
    /// A `>` on its own ends the quote's paragraph, so nothing can continue on
    /// to the next line. Neither can indented code: lazy continuation is a
    /// paragraph rule, and `>     foo` holds a code block, so the unprefixed
    /// line below it starts something of its own rather than joining the quote.
    private func quoteLineHasContent(_ lineNumber: Int) -> Bool {
        guard lineNumber >= 0, lineNumber < lines.lineCount else { return false }
        let content = lines.contentRange(lineNumber, in: text)
        var i = content.location
        let end = content.location + content.length
        while i < end, text.character(at: i) == 0x20 { i += 1 }
        while i < end, text.character(at: i) == 0x3E {
            i += 1
            if i < end, text.character(at: i) == 0x20 { i += 1 }
        }
        var column = 0
        while i < end {
            let c = text.character(at: i)
            if c == 0x20 { column += 1 } else if c == 0x09 { column += 4 - (column % 4) } else { break }
            i += 1
        }
        guard column < 4 else { return false }          // indented code
        while i < end {
            let c = text.character(at: i)
            if c != 0x20 && c != 0x09 && c != 0x0D { return true }
            i += 1
        }
        return false
    }

    /// Does the item's line at `lineNumber` leave a *paragraph* open, so the
    /// next line can continue it lazily?
    ///
    /// The list twin of `quoteLineHasContent`, and measured the same way: past
    /// the marker on the item's own first line, and relative to the item's
    /// content column everywhere else, because four columns *inside* the item
    /// is a `<pre>` and a code block leaves no paragraph to run on. Anything
    /// that is not plain text — a heading, a fence, a rule, an underline —
    /// closes the paragraph, so nothing follows it lazily either.
    private func itemParagraphIsOpen(at lineNumber: Int, itemStart: Int,
                                     info: ListInfo, cursor: inout LineCursor) -> Bool {
        guard lineNumber >= itemStart, lineNumber >= 0, lineNumber < lines.lineCount else { return false }
        let content = lines.contentRange(lineNumber, in: text)
        var inner = content
        if lineNumber == itemStart {
            let skip = min(info.contentOffset, content.length)
            inner = NSRange(location: content.location + skip, length: content.length - skip)
        }
        guard inner.length > 0 else { return false }
        let classified = cursor.classify(lineRange: inner)
        guard case .text = classified.kind else { return false }
        // On a continuation line `classified.indent` counts from the document's
        // margin, so the item's own content column has to come off it before
        // the four that mean code.
        let relative = lineNumber == itemStart
            ? classified.indent
            : max(0, classified.indent - info.contentColumn)
        return relative < 4
    }

    /// Is the item's line at `lineNumber` a table **header row** — the line a
    /// delimiter row underneath it would turn into a table?
    ///
    /// Not `itemParagraphIsOpen`, which was tried first and is a different
    /// question: that one asks whether a paragraph can be *continued lazily*,
    /// and answers no for a pipe row, because its whole job is to decide what a
    /// line of plain text below the item joins. A header row is a pipe row by
    /// definition, so asking it there rejected every table there has ever been
    /// under a list item — silently, since a rejected table is simply the item
    /// text it already was.
    ///
    /// The fence walk is the part that is not optional. A `| a | b |` inside a
    /// nested listing is a line of a program, and the line under it may well be
    /// `| --- |`; read as a header the editor would draw a grid over two lines
    /// of somebody's code.
    private func itemTableHeader(at lineNumber: Int, itemStart: Int,
                                 info: ListInfo, cursor: inout LineCursor) -> Bool {
        guard lineNumber > itemStart, lineNumber < lines.lineCount else { return false }
        let content = lines.contentRange(lineNumber, in: text)
        guard content.length > 0 else { return false }
        let classified = cursor.classify(lineRange: content)
        guard case .pipeRow = classified.kind else { return false }
        // Four columns past the item's own content is an indented code block,
        // and a listing is not a table however many pipes are in it.
        guard classified.indent - info.contentColumn < 4 else { return false }
        var fence: (marker: unichar, count: Int)?
        for probe in itemStart...lineNumber {
            let range = lines.contentRange(probe, in: text)
            guard range.length > 0 else { continue }
            guard case .fenceDelimiter(let m, let n, let fenceInfo) = cursor.classify(lineRange: range).kind
            else { continue }
            if let open = fence {
                if m == open.marker, n >= open.count, fenceInfo.isEmpty { fence = nil }
            } else {
                fence = (m, n)
            }
        }
        return fence == nil
    }

    /// Does the open list item survive the blank run starting at `line`?
    ///
    /// Looks past the blanks to the next line with content: the item continues
    /// when that line is indented to at least the item's content column, which
    /// is where its own text starts. A new marker at the outer indent, or any
    /// less-indented text, ends it — and so does the end of the document.
    private func listContinues(after line: Int, contentColumn: Int,
                               cursor: inout LineCursor) -> Bool {
        guard contentColumn > 0 else { return false }
        var probe = line + 1
        while probe < lines.lineCount {
            let info = cursor.classify(lineRange: lines.contentRange(probe, in: text))
            if case .blank = info.kind { probe += 1; continue }
            guard info.indent >= contentColumn else { return false }
            // A marker of its own starts a *nested list*, which the block model
            // already knows how to space by depth. Swallowing it into the
            // parent item hid that structure and put the parent's own margin
            // around it.
            if case .listMarker = info.kind { return false }
            return true
        }
        return false
    }

    /// Is a code fence still open inside the quote that began at `from`?
    /// Counted by walking the quote's own lines past their `>` markers, which
    /// is cheap — a quote is short — and needs no extra parser state.
    private func quoteHasOpenFence(from: Int, through: Int, cursor: inout LineCursor) -> Bool {
        var fence: (marker: unichar, count: Int)?
        for lineNumber in from...max(from, through) {
            let content = lines.contentRange(lineNumber, in: text)
            var i = content.location
            let end = content.location + content.length
            while i < end, text.character(at: i) == 0x20 { i += 1 }
            while i < end, text.character(at: i) == 0x3E {
                i += 1
                if i < end, text.character(at: i) == 0x20 { i += 1 }
            }
            guard i < end else { continue }
            let inner = NSRange(location: i, length: end - i)
            guard case .fenceDelimiter(let m, let n, let info) = cursor.classify(lineRange: inner).kind
            else { continue }
            if let open = fence {
                if m == open.marker, n >= open.count, info.isEmpty { fence = nil }
            } else {
                fence = (m, n)
            }
        }
        return fence != nil
    }

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
        case .listFence(let from, let info, _, _):
            blocks.append(make(.listItem(info), from, line))
        case .table(let from, let sawDelimiter):
            blocks.append(make(sawDelimiter ? .table : .paragraph, from, line))
        case .indentedCode(let from):
            blocks.append(make(.indentedCode, from, line))
        case .blank(let from):
            blocks.append(make(.blank, from, line))
        case .html(let from, let condition):
            // Conditions 6 and 7 end at a blank line, and the end of the
            // document ends them just as validly — there is nothing further to
            // wait for. Only 1–5 have an end *string* that can actually be
            // missing (`<!--` with no `-->`), and those alone stay open.
            //
            // Marking every EOF-terminated block unclosed meant the editor
            // never rendered an HTML block that finished a note, which is where
            // most of them sit.
            blocks.append(make(.htmlBlock(condition: condition, closed: condition >= 6), from, line))
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

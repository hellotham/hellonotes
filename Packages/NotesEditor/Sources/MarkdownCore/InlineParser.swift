//
//  InlineParser.swift
//  MarkdownCore
//
//  Single-pass inline scanner. Called with one content span (a paragraph's
//  text, a heading's title, a quote line's content …); returns the inline
//  constructs found there, in absolute UTF-16 coordinates.
//
//  Precedence: escapes, then code/math/comment spans (whose interiors are
//  opaque), then bracketed constructs, then emphasis (delimiter-run pairing
//  after the scan, CommonMark-simplified). Editor-grade by design — stable
//  and fast beats spec-complete for interactive styling.
//

import Foundation

public enum InlineParser {

    /// `references` resolves the three reference forms — `[text][label]`,
    /// `[text][]` and the bare `[text]`. It defaults to *nothing defined*, and
    /// that default is load-bearing: the shortcut form makes `[foo]` a link
    /// only because a definition for `foo` exists, so a caller with no
    /// document-wide map must find no reference links at all rather than turn
    /// every bracketed aside in the prose into one.
    public static func parse(_ text: NSString, in range: NSRange,
                             references: LinkReferenceMap = .empty) -> [InlineNode] {
        let n = range.length
        guard n > 0 else { return [] }
        var b = [unichar](repeating: 0, count: n)
        b.withUnsafeMutableBufferPointer { buf in
            text.getCharacters(buf.baseAddress!, range: range)
        }
        let base = range.location

        var nodes: [InlineNode] = []
        var delims: [Delim] = []
        var i = 0

        func abs(_ local: Int) -> Int { base + local }
        func str(_ lo: Int, _ hi: Int) -> String {
            String(utf16CodeUnits: Array(b[lo..<hi]), count: hi - lo)
        }

        while i < n {
            let c = b[i]
            switch c {
            case 0x5C: // backslash escape
                // A backslash before ASCII punctuation escapes it (GFM): the
                // `\` is a concealable marker, the punctuation is literal.
                if i + 1 < n, isASCIIPunctuation(b[i + 1]) {
                    nodes.append(InlineNode(
                        kind: .escape,
                        range: NSRange(location: abs(i), length: 2),
                        contentRange: NSRange(location: abs(i + 1), length: 1),
                        markerRanges: [NSRange(location: abs(i), length: 1)]))
                }
                i += 2

            case 0x60: // ` — code span
                var run = 0
                while i + run < n, b[i + run] == 0x60 { run += 1 }
                if let close = findRun(b, char: 0x60, length: run, from: i + run, count: n) {
                    nodes.append(span(.code, base: base, open: i, openLen: run, close: close, closeLen: run))
                    i = close + run
                } else {
                    i += run
                }

            case 0x24: // $ — inline math (block-level $$ never reaches here)
                if i + 1 < n, b[i + 1] != 0x24, b[i + 1] != 0x20,
                   let close = findChar(b, char: 0x24, from: i + 1, count: n, stopAtNewline: true),
                   close > i + 1, b[close - 1] != 0x20 {
                    nodes.append(span(.math, base: base, open: i, openLen: 1, close: close, closeLen: 1))
                    i = close + 1
                } else {
                    i += 1
                }

            case 0x25: // %% — comment
                if i + 1 < n, b[i + 1] == 0x25,
                   let close = findPair(b, char: 0x25, from: i + 2, count: n) {
                    nodes.append(span(.comment, base: base, open: i, openLen: 2, close: close, closeLen: 2))
                    i = close + 2
                } else {
                    i += 1
                }

            case 0x3D: // == — highlight
                if i + 1 < n, b[i + 1] == 0x3D, i + 2 < n,
                   let close = findPair(b, char: 0x3D, from: i + 2, count: n) {
                    nodes.append(span(.highlight, base: base, open: i, openLen: 2, close: close, closeLen: 2))
                    i = close + 2
                } else {
                    i += 1
                }

            case 0x7E: // ~~ — strikethrough
                if i + 1 < n, b[i + 1] == 0x7E, i + 2 < n,
                   let close = findPair(b, char: 0x7E, from: i + 2, count: n) {
                    nodes.append(span(.strikethrough, base: base, open: i, openLen: 2, close: close, closeLen: 2))
                    i = close + 2
                } else {
                    i += 1
                }

            case 0x21: // ! — ![[embed]] or ![image](url)
                if i + 2 < n, b[i + 1] == 0x5B, b[i + 2] == 0x5B,
                   let close = findPair(b, char: 0x5D, from: i + 3, count: n, stopAtNewline: true) {
                    let target = str(i + 3, close)
                    nodes.append(InlineNode(
                        kind: .wikiLink(target: target, isEmbed: true),
                        range: NSRange(location: abs(i), length: close + 2 - i),
                        contentRange: NSRange(location: abs(i + 3), length: close - (i + 3)),
                        markerRanges: [NSRange(location: abs(i), length: 3),
                                       NSRange(location: abs(close), length: 2)]))
                    i = close + 2
                } else if i + 1 < n, b[i + 1] == 0x5B,
                          let link = matchMDLink(b, from: i + 1, count: n) {
                    nodes.append(mdLinkNode(link, base: base, start: i, isImage: true, text: str(link.textLo, link.textHi), url: str(link.urlLo, link.urlHi)))
                    i = link.end
                } else if i + 1 < n, b[i + 1] == 0x5B,
                          let ref = matchReference(b, from: i + 1, count: n, references: references) {
                    nodes.append(refLinkNode(ref, base: base, start: i, isImage: true))
                    i = ref.end
                } else {
                    i += 1
                }

            case 0x5B: // [ — [[wiki]], [^footnote], [text](url)
                if i + 1 < n, b[i + 1] == 0x5B,
                   let close = findPair(b, char: 0x5D, from: i + 2, count: n, stopAtNewline: true) {
                    let target = str(i + 2, close)
                    nodes.append(InlineNode(
                        kind: .wikiLink(target: target, isEmbed: false),
                        range: NSRange(location: abs(i), length: close + 2 - i),
                        contentRange: NSRange(location: abs(i + 2), length: close - (i + 2)),
                        markerRanges: [NSRange(location: abs(i), length: 2),
                                       NSRange(location: abs(close), length: 2)]))
                    i = close + 2
                } else if i + 1 < n, b[i + 1] == 0x5E,
                          let close = findChar(b, char: 0x5D, from: i + 2, count: n, stopAtNewline: true),
                          close > i + 2 {
                    nodes.append(InlineNode(
                        kind: .footnoteRef(id: str(i + 2, close)),
                        range: NSRange(location: abs(i), length: close + 1 - i),
                        contentRange: NSRange(location: abs(i + 2), length: close - (i + 2)),
                        markerRanges: [NSRange(location: abs(i), length: 2),
                                       NSRange(location: abs(close), length: 1)]))
                    i = close + 1
                } else if let link = matchMDLink(b, from: i, count: n) {
                    nodes.append(mdLinkNode(link, base: base, start: i, isImage: false, text: str(link.textLo, link.textHi), url: str(link.urlLo, link.urlHi)))
                    i = link.end
                } else if let ref = matchReference(b, from: i, count: n, references: references) {
                    nodes.append(refLinkNode(ref, base: base, start: i, isImage: false))
                    i = ref.end
                } else {
                    i += 1
                }

            case 0x3C: // < — autolink, or a raw <img> tag
                if let img = matchIMGTag(b, from: i, count: n) {
                    nodes.append(InlineNode(
                        kind: .rawImage(src: str(img.srcLo, img.srcHi)),
                        range: NSRange(location: abs(i), length: img.end - i),
                        contentRange: NSRange(location: abs(i), length: 0),
                        markerRanges: []))
                    i = img.end
                } else if let close = findChar(b, char: 0x3E, from: i + 1, count: n, stopAtNewline: true),
                   isURLStart(b, at: i + 1, count: n) {
                    nodes.append(InlineNode(
                        kind: .autolink(url: str(i + 1, close)),
                        range: NSRange(location: abs(i), length: close + 1 - i),
                        contentRange: NSRange(location: abs(i + 1), length: close - (i + 1)),
                        markerRanges: [NSRange(location: abs(i), length: 1),
                                       NSRange(location: abs(close), length: 1)]))
                    i = close + 1
                } else if let end = matchRawHTML(b, from: i, count: n) {
                    // After the autolink test, never before it: `<https://x>`
                    // is a valid open tag by shape (a name, then something) and
                    // the two would otherwise race. An autolink never crosses a
                    // newline, so nothing in this family is reachable that way.
                    nodes.append(InlineNode(
                        kind: .rawHTML,
                        range: NSRange(location: abs(i), length: end - i),
                        contentRange: NSRange(location: abs(i), length: 0),
                        markerRanges: []))
                    i = end
                } else {
                    i += 1
                }

            case 0x68, 0x77: // h — bare http(s):// URL; w — bare www. URL (GFM)
                let isHTTP = isURLStart(b, at: i, count: n)
                let isWWW = !isHTTP && isWWWStart(b, at: i, count: n)
                if (isHTTP || isWWW), i == 0 || !isWordish(b[i - 1]) {
                    var j = i
                    while j < n, !isURLTerminator(b[j]) { j += 1 }
                    // Trim trailing punctuation that reads as prose.
                    while j > i, b[j-1] == 0x2E || b[j-1] == 0x2C || b[j-1] == 0x29 || b[j-1] == 0x3B { j -= 1 }
                    // A `www.` autolink links to https:// but displays as-is.
                    let display = str(i, j)
                    let url = isWWW ? "https://\(display)" : display
                    let r = NSRange(location: abs(i), length: j - i)
                    nodes.append(InlineNode(kind: .autolink(url: url), range: r, contentRange: r, markerRanges: []))
                    i = j
                } else {
                    i += 1
                }

            case 0x23: // # — tag (only after non-word boundary)
                if i == 0 || !isWordish(b[i - 1]) {
                    var j = i + 1
                    var hasAlpha = false
                    while j < n, isTagChar(b[j]) {
                        if !(b[j] >= 0x30 && b[j] <= 0x39) { hasAlpha = true }
                        j += 1
                    }
                    if j > i + 1, hasAlpha {
                        let r = NSRange(location: abs(i), length: j - i)
                        nodes.append(InlineNode(
                            kind: .tag(name: str(i + 1, j)),
                            range: r,
                            contentRange: NSRange(location: abs(i + 1), length: j - (i + 1)),
                            markerRanges: [NSRange(location: abs(i), length: 1)]))
                        i = j
                    } else {
                        i += 1
                    }
                } else {
                    i += 1
                }

            case 0x2A, 0x5F: // * _ — emphasis delimiter runs, paired later
                var run = 0
                while i + run < n, b[i + run] == c { run += 1 }
                let prev: unichar = i > 0 ? b[i - 1] : 0x20
                let next: unichar = i + run < n ? b[i + run] : 0x20
                var canOpen = !isWhitespace(next)
                var canClose = !isWhitespace(prev)
                if c == 0x5F { // _ requires word boundaries
                    canOpen = canOpen && !isWordish(prev)
                    canClose = canClose && !isWordish(next)
                }
                if canOpen || canClose {
                    delims.append(Delim(position: i, char: c, length: run, canOpen: canOpen, canClose: canClose))
                }
                i += run

            default:
                i += 1
            }
        }

        nodes.append(contentsOf: pairEmphasis(delims, base: base))
        nodes.sort { $0.range.location < $1.range.location }
        return nodes
    }

    // MARK: - Emphasis pairing

    private struct Delim {
        var position: Int
        var char: unichar
        var length: Int      // remaining unconsumed marker characters
        var canOpen: Bool
        var canClose: Bool
    }

    /// CommonMark-simplified delimiter pairing: walk left→right, closers
    /// consume the nearest compatible opener; two-character pairs become
    /// strong, single become emphasis (so `***x***` yields both).
    private static func pairEmphasis(_ input: [Delim], base: Int) -> [InlineNode] {
        var nodes: [InlineNode] = []
        var stack: [Delim] = []

        for var d in input {
            // Try to close against the stack first.
            while d.canClose, d.length > 0 {
                guard let openIdx = stack.lastIndex(where: { $0.char == d.char && $0.canOpen && $0.length > 0 }) else { break }
                var opener = stack[openIdx]
                let take = min(2, opener.length, d.length)
                let openStart = opener.position + opener.length - take
                let closeStart = d.position + (d.length - d.length) // closer consumes from its head
                let openRange = NSRange(location: base + openStart, length: take)
                let closeRange = NSRange(location: base + closeStart, length: take)
                let contentLo = openStart + take
                let contentHi = closeStart
                guard contentHi > contentLo else { break }
                nodes.append(InlineNode(
                    kind: take == 2 ? .strong : .emphasis,
                    range: NSRange(location: base + openStart, length: (closeStart + take) - openStart),
                    contentRange: NSRange(location: base + contentLo, length: contentHi - contentLo),
                    markerRanges: [openRange, closeRange]))
                opener.length -= take
                d.length -= take
                d.position += take   // closer's remaining chars sit after the consumed ones
                if opener.length == 0 {
                    // Anything above the consumed opener can no longer close
                    // below it (no cross-nesting).
                    stack.removeSubrange(openIdx...)
                } else {
                    stack[openIdx] = opener
                    stack.removeSubrange((openIdx + 1)...)
                }
            }
            if d.canOpen, d.length > 0 {
                stack.append(d)
            }
        }
        return nodes
    }

    // MARK: - Matching helpers

    private static func span(_ kind: InlineKind, base: Int, open: Int, openLen: Int, close: Int, closeLen: Int) -> InlineNode {
        InlineNode(
            kind: kind,
            range: NSRange(location: base + open, length: (close + closeLen) - open),
            contentRange: NSRange(location: base + open + openLen, length: close - (open + openLen)),
            markerRanges: [NSRange(location: base + open, length: openLen),
                           NSRange(location: base + close, length: closeLen)])
    }

    private struct MDLink {
        var textLo: Int, textHi: Int
        /// The **destination** alone — not the whole parenthesised run. See
        /// `destination(in:)`.
        var urlLo: Int, urlHi: Int
        var end: Int
    }

    /// CommonMark's link destination inside `(…)`, with the optional title
    /// left behind: `(/url "title")`, `(<my url>)`, `(/url 'title')`.
    ///
    /// The whole run used to be handed on as the URL, which reads as correct
    /// for as long as nobody writes a title — and `![photo](pic.jpg "Caption")`
    /// is the ordinary way to caption an image. The target became the
    /// nonexistent file `pic.jpg "Caption"`, so the block never resolved to an
    /// image: Edit showed a line of source where Preview drew the picture,
    /// which is the largest difference the two surfaces can have.
    /// `(<url>)` failed the same way, one file named `<url>` at a time.
    private static func destination(in b: [unichar], from lo: Int, to hi: Int) -> (Int, Int) {
        var i = lo
        while i < hi, isWhitespace(b[i]) { i += 1 }
        if i < hi, b[i] == 0x3C {                        // <destination>
            var k = i + 1
            while k < hi, b[k] != 0x3E {
                k += (b[k] == 0x5C) ? 2 : 1
            }
            // An unterminated `<` is not a destination at all; leave the run
            // whole rather than inventing a truncation.
            if k < hi { return (i + 1, k) }
            return (lo, hi)
        }
        var k = i
        while k < hi, !isWhitespace(b[k]) {
            k += (b[k] == 0x5C) ? 2 : 1
        }
        return (i, min(k, hi))
    }

    /// `[text](url)` starting at the `[` at `from`.
    /// A raw inline `<img …>` tag and the `src` inside it.
    ///
    /// Scanned with quote state, not with a search for the next `>`:
    /// `<img src="foo" title=">"/>` ends at the *second* `>`, and the corpus
    /// writes exactly that shape (`title="*"` is example 484's whole point —
    /// the `*` inside an attribute is not an emphasis delimiter, and it stops
    /// being one only because the scan above consumes the tag before the
    /// delimiter pass ever sees it).
    ///
    /// Stops at a newline like every other inline construct here. A tag split
    /// across lines is legal HTML and is not something an editor can restyle
    /// per line without the block layer's help.
    ///
    /// Returns nil when there is no `src`: a replaced element with nothing to
    /// put in it is better left as the source the writer typed.
    private static func matchIMGTag(_ b: [unichar], from i: Int, count n: Int) -> (srcLo: Int, srcHi: Int, end: Int)? {
        // `<img`, case-insensitively, then a delimiter — so `<images>` and
        // `<imgur.com>` are not tags with a missing `src`, they are not tags.
        guard i + 4 < n, b[i] == 0x3C else { return nil }
        let tag: [unichar] = [0x69, 0x6D, 0x67]   // i m g
        for (k, want) in tag.enumerated() {
            let c = b[i + 1 + k] | 0x20           // ASCII lower-case
            guard c == want else { return nil }
        }
        let after = b[i + 4]
        guard isWhitespace(after) || after == 0x3E || after == 0x2F else { return nil }

        var j = i + 4
        var quote: unichar = 0
        var end = -1
        while j < n {
            let c = b[j]
            if c == 0x0A { return nil }
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x3E {
                end = j + 1
                break
            }
            j += 1
        }
        guard end > 0 else { return nil }

        // `src=` inside the tag body, unquoted, quoted either way.
        var k = i + 4
        let body = end - 1
        while k + 4 <= body {
            let isSrc = (b[k] | 0x20) == 0x73 && (b[k + 1] | 0x20) == 0x72
                && (b[k + 2] | 0x20) == 0x63 && b[k + 3] == 0x3D
                && (k == i + 4 || isWhitespace(b[k - 1]))
            guard isSrc else { k += 1; continue }
            var v = k + 4
            if v < body, b[v] == 0x22 || b[v] == 0x27 {
                let q = b[v]
                v += 1
                var e = v
                while e < body, b[e] != q { e += 1 }
                return e > v ? (v, e, end) : nil
            }
            var e = v
            while e < body, !isWhitespace(b[e]), b[e] != 0x2F { e += 1 }
            return e > v ? (v, e, end) : nil
        }
        return nil
    }

    /// A raw inline HTML tag or comment starting at the `<` at `from`, and
    /// where it ends.
    ///
    /// The grammar is `HTMLBlockShape.tagEnd`'s, not one of this file's own,
    /// and that is the whole implementation. A scan that merely took everything
    /// up to the next `>` reads `<foo bar=baz⏎bim!bop />` as a tag — `bim!bop`
    /// is not an attribute name, so cmark reads it as literal text and the page
    /// prints two lines. It cost spec #640, which had been passing.
    ///
    /// **It is allowed to cross a line ending, and that is the point.** Every
    /// other construct here stops at a newline, because a construct an editor
    /// cannot restyle per line is a construct it used to leave as source. A raw
    /// tag is the case where leaving it as source is wrong twice over: cmark
    /// eats the newline into the token, so the page draws one line where the
    /// editor drew two, and the `*` or `_` sitting in an attribute becomes an
    /// emphasis delimiter that reaches out and italicises the rest of the
    /// paragraph. A blank line cannot appear here — the scanner is given one
    /// block's content, and a blank line is what ends a paragraph.
    private static func matchRawHTML(_ b: [unichar], from i: Int, count n: Int) -> Int? {
        HTMLBlockShape.tagEnd(b, from: i, count: n)
    }

    /// `[text](url)` starting at the `[` at `from`.
    private static func matchMDLink(_ b: [unichar], from: Int, count: Int) -> MDLink? {
        guard b[from] == 0x5B else { return nil }
        var i = from + 1
        var depth = 1
        while i < count, depth > 0 {
            if b[i] == 0x0A { return nil }
            if b[i] == 0x5C { i += 2; continue }
            if b[i] == 0x5B { depth += 1 }
            if b[i] == 0x5D { depth -= 1 }
            i += 1
        }
        guard depth == 0, i < count, b[i] == 0x28 else { return nil }
        let textHi = i - 1
        let urlLo = i + 1
        var j = urlLo
        var parens = 1
        var crossesLine = false
        // A line ending inside `(…)` is whitespace, not a terminator:
        // `[link](   /uri⏎  "title"  )` is one link, and cmark gives the page
        // one line for it. The **label** still stops at a newline — that is a
        // wider change than this family, and an unpaired `[` two lines up would
        // start claiming prose as link text.
        while j < count, parens > 0 {
            if b[j] == 0x0A { crossesLine = true }
            if b[j] == 0x28 { parens += 1 }
            if b[j] == 0x29 { parens -= 1 }
            j += 1
        }
        guard parens == 0 else { return nil }
        // Only *where whitespace is allowed*, though, and that is the whole of
        // the rule. `[link](foo⏎bar)` is not a link — an unquoted destination
        // may not contain a line ending, so cmark leaves both lines as literal
        // text and the page draws two of them. The strict shape is checked only
        // when a line ending is actually there, so every single-line link keeps
        // the lenient scan this parser has always used.
        if crossesLine, !parensAllowLineEnding(b, from: urlLo, to: j - 1) { return nil }
        let (destLo, destHi) = destination(in: b, from: urlLo, to: j - 1)
        return MDLink(textLo: from + 1, textHi: textHi, urlLo: destLo, urlHi: destHi, end: j)
    }

    /// Is the run between a link's parentheses one CommonMark would still read
    /// as a destination (and optional title) with a line ending in it?
    ///
    /// `ws* destination ws* title? ws*`, where the destination is either
    /// `<…>` — which may not contain a line ending at all — or an unbroken run
    /// of non-whitespace, and a title is quoted or parenthesised. Anything else
    /// with a newline in it is two lines of prose that happen to have brackets
    /// in them, and reading it as a link conceals half of the second line.
    private static func parensAllowLineEnding(_ b: [unichar], from lo: Int, to hi: Int) -> Bool {
        var i = lo
        func skipWhitespace() { while i < hi, isWhitespace(b[i]) { i += 1 } }
        skipWhitespace()
        if i < hi, b[i] == 0x3C {                       // <destination>
            i += 1
            while i < hi, b[i] != 0x3E, b[i] != 0x0A { i += (b[i] == 0x5C) ? 2 : 1 }
            guard i < hi, b[i] == 0x3E else { return false }
            i += 1
        } else {
            let start = i
            while i < hi, !isWhitespace(b[i]) { i += (b[i] == 0x5C) ? 2 : 1 }
            i = min(i, hi)
            guard i > start else { return false }
        }
        skipWhitespace()
        guard i < hi else { return true }               // destination alone
        let quote = b[i]
        let closer: unichar = quote == 0x28 ? 0x29 : quote
        guard quote == 0x22 || quote == 0x27 || quote == 0x28 else { return false }
        i += 1
        while i < hi, b[i] != closer { i += (b[i] == 0x5C) ? 2 : 1 }
        guard i < hi else { return false }
        i += 1
        skipWhitespace()
        return i >= hi
    }

    private struct RefLink {
        /// The label the reader sees — the first bracket's contents.
        var textLo: Int, textHi: Int
        var end: Int
        var url: String
    }

    /// The three reference forms at the `[` at `from`: full `[text][label]`,
    /// collapsed `[text][]`, and shortcut `[text]`.
    ///
    /// Which one it is turns entirely on what follows the first bracket, and
    /// the shortcut is the dangerous one: `[see note]` is a link if and only
    /// if a `[see note]: …` definition exists, and is ordinary prose
    /// otherwise. So nothing is matched that does not resolve.
    ///
    /// A *second* bracket is consulted even when it fails to resolve, and the
    /// failure is final rather than a fallback to the shortcut. CommonMark is
    /// explicit that a label followed by a link label is not a shortcut, so
    /// `[foo][bar]` with only `foo` defined stays text — treating it as
    /// `[foo]` plus a literal `[bar]` would link half of it.
    private static func matchReference(_ b: [unichar], from: Int, count: Int,
                                       references: LinkReferenceMap) -> RefLink? {
        guard !references.isEmpty, b[from] == 0x5B,
              let textEnd = closingBracket(b, from: from, count: count) else { return nil }
        let textLo = from + 1, textHi = textEnd
        var labelLo = textLo, labelHi = textHi
        var end = textEnd + 1
        // `[]` is collapsed — the text is its own label; `[bar]` is full. An
        // opening bracket with no `]` after it is neither, and the construct
        // falls back to the shortcut rather than failing outright.
        if end < count, b[end] == 0x5B, let close = closingBracket(b, from: end, count: count) {
            if close > end + 1 { labelLo = end + 1; labelHi = close }
            end = close + 1
        }
        guard labelHi > labelLo else { return nil }
        let label = String(utf16CodeUnits: Array(b[labelLo..<labelHi]), count: labelHi - labelLo)
        guard let target = references[label] else { return nil }
        return RefLink(textLo: textLo, textHi: textHi, end: end, url: target.destination)
    }

    /// The `]` closing the `[` at `from`. Brackets nest and a backslash
    /// escapes the next character; newlines do not stop the scan, because a
    /// link label may be written across lines.
    private static func closingBracket(_ b: [unichar], from: Int, count: Int) -> Int? {
        var i = from + 1
        var depth = 1
        while i < count {
            let c = b[i]
            if c == 0x5C { i += 2; continue }
            if c == 0x5B { depth += 1 }
            if c == 0x5D {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// The same shape `mdLinkNode` produces — opener marker, label content,
    /// and everything from the closing `]` onward as the tail marker — so a
    /// reference link is indistinguishable downstream from an inline one.
    private static func refLinkNode(_ ref: RefLink, base: Int, start: Int, isImage: Bool) -> InlineNode {
        InlineNode(
            kind: .link(url: ref.url, isImage: isImage),
            range: NSRange(location: base + start, length: ref.end - start),
            contentRange: NSRange(location: base + ref.textLo, length: ref.textHi - ref.textLo),
            markerRanges: [
                NSRange(location: base + start, length: ref.textLo - start),
                NSRange(location: base + ref.textHi, length: ref.end - ref.textHi),
            ])
    }

    private static func mdLinkNode(_ link: MDLink, base: Int, start: Int, isImage: Bool, text: String, url: String) -> InlineNode {
        _ = text
        return InlineNode(
            kind: .link(url: url, isImage: isImage),
            range: NSRange(location: base + start, length: link.end - start),
            contentRange: NSRange(location: base + link.textLo, length: link.textHi - link.textLo),
            markerRanges: [
                NSRange(location: base + start, length: link.textLo - start),
                NSRange(location: base + link.textHi, length: link.end - link.textHi),
            ])
    }

    /// ASCII punctuation, per the GFM backslash-escape rule.
    private static func isASCIIPunctuation(_ c: unichar) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) ||
        (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }

    private static func findRun(_ b: [unichar], char: unichar, length: Int, from: Int, count: Int) -> Int? {
        var i = from
        while i < count {
            if b[i] == char {
                var run = 0
                while i + run < count, b[i + run] == char { run += 1 }
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func findChar(_ b: [unichar], char: unichar, from: Int, count: Int, stopAtNewline: Bool = false) -> Int? {
        var i = from
        while i < count {
            if b[i] == 0x5C { i += 2; continue }
            if stopAtNewline, b[i] == 0x0A { return nil }
            if b[i] == char { return i }
            i += 1
        }
        return nil
    }

    /// First occurrence of a doubled `char` (e.g. `]]`, `==`) at/after `from`.
    private static func findPair(_ b: [unichar], char: unichar, from: Int, count: Int, stopAtNewline: Bool = false) -> Int? {
        var i = from
        while i + 1 < count {
            if b[i] == 0x5C { i += 2; continue }
            if stopAtNewline, b[i] == 0x0A { return nil }
            if b[i] == char, b[i + 1] == char { return i }
            i += 1
        }
        return nil
    }

    private static func isURLStart(_ b: [unichar], at i: Int, count: Int) -> Bool {
        // "http://" or "https://"
        let http: [unichar] = [0x68, 0x74, 0x74, 0x70]
        guard i + 7 <= count else { return false }
        for (k, u) in http.enumerated() where b[i + k] != u { return false }
        var j = i + 4
        if j < count, b[j] == 0x73 { j += 1 }  // s
        guard j + 3 <= count, b[j] == 0x3A, b[j+1] == 0x2F, b[j+2] == 0x2F else { return false }
        return true
    }

    private static func isWWWStart(_ b: [unichar], at i: Int, count: Int) -> Bool {
        // "www." followed by at least one more char (GFM extended autolink).
        let www: [unichar] = [0x77, 0x77, 0x77, 0x2E]
        guard i + 5 <= count else { return false }
        for (k, u) in www.enumerated() where b[i + k] != u { return false }
        return true
    }

    private static func isURLTerminator(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x3C || c == 0x3E || c == 0x22
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isWordish(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }

    private static func isTagChar(_ c: unichar) -> Bool {
        isWordish(c) || c == 0x2F || c == 0x2D
    }
}

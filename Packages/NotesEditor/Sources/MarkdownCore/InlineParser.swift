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

    public static func parse(_ text: NSString, in range: NSRange) -> [InlineNode] {
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
                } else {
                    i += 1
                }

            case 0x3C: // < — autolink
                if let close = findChar(b, char: 0x3E, from: i + 1, count: n, stopAtNewline: true),
                   isURLStart(b, at: i + 1, count: n) {
                    nodes.append(InlineNode(
                        kind: .autolink(url: str(i + 1, close)),
                        range: NSRange(location: abs(i), length: close + 1 - i),
                        contentRange: NSRange(location: abs(i + 1), length: close - (i + 1)),
                        markerRanges: [NSRange(location: abs(i), length: 1),
                                       NSRange(location: abs(close), length: 1)]))
                    i = close + 1
                } else {
                    i += 1
                }

            case 0x68: // h — bare http(s):// URL
                if isURLStart(b, at: i, count: n), i == 0 || !isWordish(b[i - 1]) {
                    var j = i
                    while j < n, !isURLTerminator(b[j]) { j += 1 }
                    // Trim trailing punctuation that reads as prose.
                    while j > i, b[j-1] == 0x2E || b[j-1] == 0x2C || b[j-1] == 0x29 || b[j-1] == 0x3B { j -= 1 }
                    let r = NSRange(location: abs(i), length: j - i)
                    nodes.append(InlineNode(kind: .autolink(url: str(i, j)), range: r, contentRange: r, markerRanges: []))
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
        var urlLo: Int, urlHi: Int
        var end: Int
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
        while j < count, parens > 0 {
            if b[j] == 0x0A { return nil }
            if b[j] == 0x28 { parens += 1 }
            if b[j] == 0x29 { parens -= 1 }
            j += 1
        }
        guard parens == 0 else { return nil }
        return MDLink(textLo: from + 1, textHi: textHi, urlLo: urlLo, urlHi: j - 1, end: j)
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

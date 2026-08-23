//
//  ReferenceDefinition.swift
//  MarkdownCore
//
//  `[label]: /url "title"` — source the reader never sees.
//
//  The editor finds these by inversion: ask cmark which source its block nodes
//  cover, and whatever is left over is source that produced nothing. That is
//  exact when the definition stands alone, and blind whenever it does not — a
//  container node covers its children *and* the definitions consumed between
//  them, so a definition inside a list item, or one sitting above a paragraph
//  in the same block, reads as covered. cmark-gfm has no node for a reference
//  definition to ask about either, so there is nothing subtler to consult.
//
//  Hence one construct recognised outright. The rule that matters is *where*:
//  a definition is only a definition at the start of a paragraph-like block, or
//  following another one. `foo` then `[bar]: /url` is two lines of one
//  paragraph to CommonMark, because a definition cannot interrupt a paragraph —
//  and hiding that second line would delete text the reader can see.
//

import Foundation

public enum ReferenceDefinition {

    /// What a definition says: the label as written (brackets stripped, not
    /// normalised — `LinkReferenceMap` folds it), and what it stands for.
    public struct Definition: Sendable, Equatable {
        public var label: String
        public var destination: String
        public var title: String

        public init(label: String, destination: String, title: String) {
            self.label = label
            self.destination = destination
            self.title = title
        }
    }

    /// Is the line at `range` (its content, newline excluded) a link reference
    /// definition on its own?
    public static func matches(_ text: NSString, contentRange range: NSRange) -> Bool {
        parse(text, contentRange: range) != nil
    }

    /// The definition at `range`, or nil when the line is not one.
    ///
    /// This file used to answer `matches` and nothing else, because the only
    /// question anyone asked of a definition was whether to *hide* it. Drawing
    /// `![foo]` as a picture needs the other half — the destination the label
    /// stands for — and reading it back out with a second scanner somewhere
    /// else would be two parsers with two ideas of what a definition is, which
    /// is exactly how a line gets concealed by one and resolved by neither.
    public static func parse(_ text: NSString, contentRange range: NSRange) -> Definition? {
        var i = range.location
        let end = range.location + range.length
        var indent = 0
        while i < end, text.character(at: i) == 0x20, indent < 4 { i += 1; indent += 1 }
        guard indent < 4, i < end, text.character(at: i) == 0x5B else { return nil }     // `[`
        i += 1

        // Label: up to an unescaped `]`, and carrying at least one character
        // that is not whitespace. Counting characters instead let `[\n ]: /uri`
        // through — a label of a newline and a space is not empty, so the count
        // said "definition" and the whole construct was concealed. CommonMark
        // says a link label needs a non-whitespace character, and cmark agrees:
        // it leaves those four lines as two paragraphs the reader can see, so
        // hiding them cost the note 64pt of text.
        var labelHasContent = false
        let labelLo = i
        while i < end {
            let c = text.character(at: i)
            if c == 0x5C, i + 1 < end { i += 2; labelHasContent = true; continue }       // `\x`
            if c == 0x5D { break }
            if c == 0x5B { return nil }                                                 // nested `[`
            if !isSpace(c) { labelHasContent = true }
            i += 1
        }
        guard i < end, text.character(at: i) == 0x5D, labelHasContent else { return nil }
        let label = text.substring(with: NSRange(location: labelLo, length: i - labelLo))
        i += 1
        guard i < end, text.character(at: i) == 0x3A else { return nil }                 // `:`
        i += 1

        while i < end, isSpace(text.character(at: i)) { i += 1 }
        // Destination: `<…>`, or a run of non-space characters.
        var destLo = i, destHi = i
        if i < end, text.character(at: i) == 0x3C {                                      // `<`
            i += 1
            destLo = i
            var closed = false
            while i < end {
                let c = text.character(at: i)
                if c == 0x5C, i + 1 < end { i += 2; continue }
                if c == 0x3E { destHi = i; closed = true; i += 1; break }
                if c == 0x3C { return nil }
                i += 1
            }
            guard closed else { return nil }
            // A title has to be separated from the destination by whitespace.
            // `[foo]: <bar>(baz)` is *not* a definition — cmark leaves the
            // whole line as a paragraph, and collapsing it hid a line of text.
            if i < end, !isSpace(text.character(at: i)) { return nil }
        } else {
            var destination = 0
            while i < end, !isSpace(text.character(at: i)) { i += 1; destination += 1 }
            guard destination > 0 else { return nil }
            destHi = i
        }
        let destinationText = text.substring(with: NSRange(location: destLo, length: destHi - destLo))

        while i < end, isSpace(text.character(at: i)) { i += 1 }
        if i >= end {                                                                    // no title
            return Definition(label: label, destination: destinationText, title: "")
        }

        // Title: quoted, and nothing may follow it but spaces. `"title" ok` is
        // *not* a definition — CommonMark backs the title out and the line
        // becomes a paragraph, which is exactly the case that must not hide.
        let quote = text.character(at: i)
        guard quote == 0x22 || quote == 0x27 || quote == 0x28 else { return nil }
        let closing: unichar = quote == 0x28 ? 0x29 : quote
        i += 1
        let titleLo = i
        while i < end, text.character(at: i) != closing {
            if text.character(at: i) == 0x5C, i + 1 < end { i += 1 }
            i += 1
        }
        guard i < end else { return nil }
        let title = text.substring(with: NSRange(location: titleLo, length: i - titleLo))
        i += 1
        while i < end, isSpace(text.character(at: i)) { i += 1 }
        guard i >= end else { return nil }
        return Definition(label: label, destination: destinationText, title: title)
    }

    /// A definition and the source it occupies.
    public struct Found: Sendable, Equatable {
        /// The span the editor conceals — the definition alone, past any list
        /// marker or `>` chrome in front of it.
        public var range: NSRange
        public var definition: Definition

        public init(range: NSRange, definition: Definition) {
            self.range = range
            self.definition = definition
        }
    }

    /// Every definition in the document, in source order.
    ///
    /// This walk used to live in `EditorDocument`, where the only thing wanted
    /// from it was a list of ranges to hide — the definitions it *read* on the
    /// way were thrown away, and `![foo]` then had nothing to resolve against.
    /// One walk answers both questions, which is what keeps the concealed set
    /// and the resolvable set from being two different sets.
    ///
    /// Taken from the *start* of a paragraph-like block and no further: a
    /// definition cannot interrupt a paragraph, so `foo` then `[bar]: /url` is
    /// two lines of one paragraph and the second line is text the reader sees.
    public static func all(in text: NSString, document: ParseResult) -> [Found] {
        var out: [Found] = []
        for block in document.blocks {
            switch block.kind {
            // Headings too: a setext heading's own paragraph may open with
            // definitions — `[foo]: /url` / `bar` / `===` is a consumed
            // definition and an h1 over `bar` alone, not an h1 three lines tall.
            case .paragraph, .listItem, .blockquote, .heading: break
            default: continue
            }
            let last = block.firstLine + block.lineCount - 1
            // A definition may start where a block starts, after a blank line,
            // or after another definition — the three places a new paragraph
            // could have begun. Anywhere else it is a continuation line, and
            // continuation lines are text.
            var couldStart = true
            var skipUntil = block.firstLine
            for lineNumber in block.firstLine...last {
                if lineNumber < skipUntil { continue }
                let content = document.lines.contentRange(lineNumber, in: text)
                if isBlank(content, in: text) {
                    couldStart = true
                    continue
                }
                // Inside a list item the definition sits past the marker, so
                // the marker line's own content starts after it.
                var scan = content
                if lineNumber == block.firstLine, case .listItem(let info) = block.kind {
                    let skip = min(info.contentOffset, content.length)
                    scan = NSRange(location: content.location + skip, length: content.length - skip)
                }
                if case .blockquote = block.kind {
                    // Past the `>` markers, which are chrome rather than content.
                    var j = scan.location
                    let stop = scan.location + scan.length
                    while j < stop, text.character(at: j) == 0x20 { j += 1 }
                    while j < stop, text.character(at: j) == 0x3E {
                        j += 1
                        if j < stop, text.character(at: j) == 0x20 { j += 1 }
                    }
                    scan = NSRange(location: j, length: stop - j)
                }
                // A definition may run over several lines. Try the longest
                // span first, so `[` / `foo` / `]: /url` is one definition
                // rather than three lines of text — but only spans that end on
                // a line boundary, and never past the block.
                var matched = 0
                if couldStart {
                    for span in stride(from: min(3, last - lineNumber + 1), through: 1, by: -1) {
                        let endLine = lineNumber + span - 1
                        let endContent = document.lines.contentRange(endLine, in: text)
                        let whole = NSRange(location: scan.location,
                                            length: endContent.location + endContent.length - scan.location)
                        guard whole.length > 0 else { continue }
                        if let definition = parse(text, contentRange: whole) {
                            out.append(Found(range: whole, definition: definition))
                            matched = span
                            break
                        }
                    }
                }
                if matched > 0 {
                    skipUntil = lineNumber + matched
                } else {
                    couldStart = false
                }
            }
        }
        return out
    }

    /// Whether a line's content holds nothing but spaces and tabs.
    private static func isBlank(_ content: NSRange, in text: NSString) -> Bool {
        for offset in 0..<content.length {
            let c = text.character(at: content.location + offset)
            if c != 0x20 && c != 0x09 { return false }
        }
        return true
    }

    /// Whitespace, newlines included — a definition may be written across
    /// several lines (`[\n foo \n]: /url`), and the spec counts the line
    /// breaks inside it as ordinary whitespace.
    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
    }
}

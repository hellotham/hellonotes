//
//  ParagraphInsertion.swift
//  MarkdownCore
//
//  A block put in on purpose — a picture from Insert Image — as a paragraph
//  of its own, inside whatever holds the caret's line.
//
//  A paragraph of its own is blank lines around it, and that was all it was:
//  at a caret in a callout — Obsidian's usual frame for a figure — the picture
//  landed after the callout, and in a list item it split the list in two,
//  because a line without the container's markers is not in the container.
//  So every line the insertion adds carries them: a quote's `>` as the line
//  writes it, and a list item's indent to its text.
//

import Foundation

public enum ParagraphInsertion {

    /// What holds a line: what each line of a paragraph put inside it begins
    /// with — the quote markers, as the line writes them, and a list item's
    /// indent to its text. Empty for a line nothing holds.
    public struct Container: Equatable, Sendable {
        public let prefix: String

        public init(prefix: String) { self.prefix = prefix }

        public static let none = Container(prefix: "")

        /// A blank line inside it: the quote markers alone — and nothing at
        /// all in a list item, where a blank line is empty.
        public var blank: String {
            var blank = prefix
            while let last = blank.last, last == " " || last == "\t" { blank.removeLast() }
            return blank
        }
    }

    /// The container of the line at `location`, by the document's parse: a
    /// list item — the indent to its text, inside any quote — or a quote or
    /// callout. `.none` anywhere else, and in a fence inside either, whose
    /// lines are code.
    ///
    /// A list item is a block from its marker line (`BlockKind.listItem`), so
    /// a line of its own text below that line takes the item's indent from
    /// the marker line. Not handled, and left as before: a list inside a quote
    /// read from one of its items' continuation lines, which takes the quote
    /// alone; and a blank line between an item's paragraphs, which is a block
    /// of its own.
    public static func container(in text: NSString, at location: Int, parse: ParseResult) -> Container {
        guard location >= 0, location <= text.length, let index = parse.blockIndex(at: lineStart(location, in: text))
        else { return .none }
        let start = lineStart(location, in: text)
        let block = parse.blocks[index]
        let isItem: Bool
        switch block.kind {
        case .listItem: isItem = true
        case .blockquote: isItem = false
        default: return .none
        }
        guard !ListContinuation.isInsideFence(start, from: block.range.location, in: text) else { return .none }
        let line = Self.line(at: start, in: text)
        if let item = ListContinuation.parse(line) { return Container(prefix: textIndent(of: item)) }
        let own = quoteMarkers(of: line)
        let first = Self.line(at: lineStart(block.range.location, in: text), in: text)
        if isItem, let item = ListContinuation.parse(first) {
            return Container(prefix: (own.isEmpty ? item.container : own) + item.indent
                             + String(repeating: " ", count: markerWidth(of: item)))
        }
        let quote = own.isEmpty ? quoteMarkers(of: first) : own
        guard !quote.isEmpty else { return .none }
        return Container(prefix: quote.hasSuffix(" ") ? quote : quote + " ")
    }

    /// `markdown` as a paragraph of its own at `range`, inside `container`:
    /// the text that goes in, and the range it replaces.
    ///
    /// With no container, a blank line before it unless the note starts there
    /// or one is there already, and after it unless the note ends there or one
    /// is there — counted in newlines, as it always was. Inside one, the same
    /// by lines: a blank line is the container's own (`Container.blank`), and
    /// the picture's line and any text the caret splits off carry its prefix.
    /// A caret among a line's markers is taken to the line's text first, so a
    /// picture asked for at the start of `> text` goes inside the quote rather
    /// than in front of its `>` — the range returned says where.
    public static func paragraph(_ markdown: String, at range: NSRange, in text: NSString,
                                 container: Container) -> (range: NSRange, text: String) {
        guard !container.prefix.isEmpty else {
            return (range, bare(markdown, at: range, in: text))
        }
        let prefix = container.prefix
        let blank = container.blank
        var range = range
        let start = lineStart(range.location, in: text)
        let line = Self.line(at: start, in: text)
        let item = ListContinuation.parse(line)
        let textStart = start + (item?.prefixLength ?? markerRun(of: line))
        if range.length == 0, range.location < textStart { range.location = textStart }
        let end = NSMaxRange(range)

        let before: String
        if hasText(text, from: textStart, to: range.location) {
            before = "\n" + blank + "\n" + prefix
        } else if item != nil || start == 0 || isBlank(Self.line(at: lineStart(start - 1, in: text), in: text)) {
            // Right after an item's marker the picture is the item's first
            // block; after a blank line, or at the top, it needs none.
            before = ""
        } else {
            // This line, holding only its markers so far, is the blank one.
            before = "\n" + prefix
        }

        let endLine = text.lineRange(for: NSRange(location: end, length: 0))
        let after: String
        if hasText(text, from: end, to: lineEnd(endLine, in: text)) {
            after = "\n" + blank + "\n" + prefix
        } else if NSMaxRange(endLine) >= text.length, lineEnd(endLine, in: text) == NSMaxRange(endLine) {
            after = ""                                        // the note ends here
        } else if isBlank(Self.line(at: NSMaxRange(endLine), in: text)) {
            after = ""
        } else {
            after = "\n" + blank
        }
        return (range, before + markdown + after)
    }

    // MARK: - Lines

    /// The insertion with nothing holding it: blank lines by newlines.
    private static func bare(_ markdown: String, at range: NSRange, in text: NSString) -> String {
        func newlines(_ indices: StrideTo<Int>) -> Int {
            var count = 0
            for index in indices {
                guard text.character(at: index) == 0x0A else { break }
                count += 1
                if count == 2 { break }
            }
            return count
        }
        let end = NSMaxRange(range)
        let before = range.location == 0 ? 2 : newlines(stride(from: range.location - 1, to: -1, by: -1))
        let after = end >= text.length ? 2 : newlines(stride(from: end, to: text.length, by: 1))
        return String(repeating: "\n", count: 2 - before) + markdown + String(repeating: "\n", count: 2 - after)
    }

    private static func lineStart(_ location: Int, in text: NSString) -> Int {
        text.lineRange(for: NSRange(location: min(max(0, location), text.length), length: 0)).location
    }

    /// Where `line`'s text ends: before its newline, `\r\n` or `\n`.
    private static func lineEnd(_ line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        if end > line.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        if end > line.location, text.character(at: end - 1) == 0x0D { end -= 1 }
        return end
    }

    /// The line starting at `start`, without its newline — empty past the end.
    private static func line(at start: Int, in text: NSString) -> String {
        guard start < text.length else { return "" }
        let line = text.lineRange(for: NSRange(location: start, length: 0))
        return text.substring(with: NSRange(location: line.location, length: lineEnd(line, in: text) - line.location))
    }

    /// Whether a line holds nothing but markers and space — blank, inside a
    /// quote or out of one.
    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" }
    }

    private static func hasText(_ text: NSString, from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        return text.substring(with: NSRange(location: from, length: to - from))
            .contains { !$0.isWhitespace }
    }

    /// The length of a line's leading markers and space — where its text
    /// begins when it is not a list item's marker line.
    private static func markerRun(of line: String) -> Int {
        var count = 0
        for unit in line.utf16 {
            guard unit == 0x20 || unit == 0x09 || unit == 0x3E else { break }
            count += 1
        }
        return count
    }

    /// A line's quote markers as it writes them — up to three spaces, `>`,
    /// and a space after it, as many times as it is nested.
    private static func quoteMarkers(of line: String) -> String {
        let units = Array(line.utf16)
        var index = 0
        var end = 0
        while true {
            var probe = index
            while probe < units.count, probe - index < 3, units[probe] == 0x20 { probe += 1 }
            guard probe < units.count, units[probe] == 0x3E else { break }
            probe += 1
            if probe < units.count, units[probe] == 0x20 { probe += 1 }
            index = probe
            end = probe
        }
        return String(utf16CodeUnits: Array(units[0..<end]), count: end)
    }

    /// A list item's text column, as the prefix of a paragraph inside it: its
    /// quote, its indent, and spaces the width of its marker and the space
    /// after it — not its task box, which its later paragraphs do not sit past.
    private static func textIndent(of item: ListContinuation.Item) -> String {
        item.container + item.indent + String(repeating: " ", count: markerWidth(of: item))
    }

    /// The marker and the space after it. Five spaces or more after a marker
    /// are the marker's one and an indented code block's four.
    private static func markerWidth(of item: ListContinuation.Item) -> Int {
        let spacing = item.spacing.utf16.count
        return item.bullet.utf16.count + item.delimiter.utf16.count + (spacing >= 5 ? 1 : max(1, spacing))
    }
}

//
//  ListContinuation.swift
//  MarkdownCore
//
//  What Return does on a line of a list: starts the next item.
//
//  It did nothing of the kind — Return in a list was a bare newline, so every
//  item after the first had its marker typed by hand, and the line after the
//  list kept the list's indent on screen until it was styled again. The rule
//  is the one every Markdown editor people write in has settled on:
//
//  - In an item with text, Return splits it at the caret and the second half
//    starts a new item: the same bullet, or the next number with the same
//    delimiter, at the same indent, inside the same quote — and an unchecked
//    box when the item was a task.
//  - In an empty item, Return ends the list instead: a nested item moves out
//    to its parent's level, and a top-level one loses its marker and leaves a
//    blank line after the list, the caret below it at the list's own margin.
//    The blank line is not decoration: a line typed straight after an item
//    is, in Markdown, more of that item (a lazy continuation), and would be
//    drawn — and rendered by GitHub — inside the list.
//  - Before the item's text — the caret in its marker — it is a plain newline.
//
//  Text only: whether the line is prose at all (not code, front matter or
//  maths) is the caller's to know, from its parse.
//

import Foundation

public enum ListContinuation {

    /// One edit to make instead of inserting a newline.
    public struct Edit: Equatable, Sendable {
        /// The range to replace.
        public let range: NSRange
        /// What replaces it.
        public let replacement: String
        /// Where the caret goes after.
        public let caret: Int
    }

    /// The parts of a list item's first line, up to its text.
    struct Item: Equatable {
        /// Leading whitespace and quote markers, kept as written.
        var container: String
        /// Spaces before the marker, inside the container.
        var indent: String
        /// `-`, `*`, `+`, or the number.
        var bullet: String
        /// `.` or `)` for a numbered item; empty for a bullet.
        var delimiter: String
        /// What separates the marker from the text, as written.
        var spacing: String
        /// `[ ] `, `[x] `… when the item is a task, as written.
        var task: String
        /// The length of everything above, in UTF-16 units.
        var prefixLength: Int

        var isOrdered: Bool { !delimiter.isEmpty }
        var number: Int? { isOrdered ? Int(bullet) : nil }
    }

    /// What Return does at `caret`, given the document's parse — only on a
    /// line the parse puts in a list item or a quote: never in code (a fence
    /// of its own, or one inside an item or a quote), front matter or maths,
    /// and never on a setext heading's `-` underline, which reads as an empty
    /// item line by itself.
    public static func returnKey(in text: NSString, at caret: Int, parse: ParseResult) -> Edit? {
        guard caret >= 0, caret <= text.length else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        guard let index = parse.blockIndex(at: lineStart) else { return nil }
        let block = parse.blocks[index]
        switch block.kind {
        case .listItem, .blockquote:
            // The block's kind is not the whole answer: a fence written under
            // an item, or inside a quote, is part of that item's or quote's
            // block — a YAML listing under a numbered step, every line of it
            // reading `- name: x`.
            guard !isInsideFence(lineStart, from: block.range.location, in: text) else { return nil }
            return returnKey(in: text, at: caret)
        default: return nil
        }
    }

    /// Whether the line at `lineStart` lies inside a code fence opened at or
    /// after `blockStart` and not yet closed — read past each line's indent and
    /// quote markers, since the fence belongs to a container.
    static func isInsideFence(_ lineStart: Int, from blockStart: Int, in text: NSString) -> Bool {
        var open: (marker: unichar, count: Int)?
        var cursor = blockStart
        while cursor < lineStart, cursor < text.length {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            let content = text.substring(with: line)
            let units = Array(content.utf16)
            // Only a line holding a fence character can open or close one.
            guard units.contains(0x60) || units.contains(0x7E) else {
                cursor = max(cursor + 1, NSMaxRange(line))
                continue
            }
            var i = 0
            while i < units.count, units[i] == 0x20 || units[i] == 0x09 || units[i] == 0x3E { i += 1 }
            // A list marker in front of the fence on the item's own line.
            if open == nil, let item = parse(content.trimmingCharacters(in: .newlines)) {
                i = max(i, item.prefixLength)
            }
            if i < units.count, units[i] == 0x60 || units[i] == 0x7E {      // ` ~
                let marker = units[i]
                var run = 0
                while i + run < units.count, units[i + run] == marker { run += 1 }
                if run >= 3 {
                    if let fence = open {
                        let rest = units[(i + run)...].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
                        if fence.marker == marker, run >= fence.count, rest { open = nil }
                    } else {
                        open = (marker, run)
                    }
                }
            }
            cursor = max(cursor + 1, NSMaxRange(line))
        }
        return open != nil
    }

    /// The longest note `returnKey(parsing:)` will parse, in UTF-16 units —
    /// the cap the editor's other whole-note pass on the main actor has
    /// (`StyleApplier.gfmOverlayMaxLength`). Past it Return is a plain newline.
    ///
    /// The parse runs on the main actor, on a keystroke, at about 4.5ms per MB
    /// (measured, release): 1.4ms here, and past the package's own 5ms
    /// keystroke budget near 1.1MB with nothing to stop it.
    public static let parseLimit = 200_000

    /// The same, for a view that keeps no parse — the Markdown pane. The whole
    /// note is parsed, and only when the caret's line reads as an item at all,
    /// so a Return anywhere else costs a line's read — and never a note past
    /// `parseLimit`.
    public static func returnKey(parsing text: NSString, at caret: Int) -> Edit? {
        guard caret >= 0, caret <= text.length, text.length <= parseLimit else { return nil }
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        guard parse(text.substring(with: line).trimmingCharacters(in: .newlines)) != nil else { return nil }
        return returnKey(in: text, at: caret, parse: BlockParser.fullParse(text))
    }

    /// What Return does at `caret` in `text`, or `nil` for a plain newline —
    /// reading the line alone; the caller has checked it is in a list.
    public static func returnKey(in text: NSString, at caret: Int) -> Edit? {
        guard caret >= 0, caret <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        var end = NSMaxRange(line)
        if end > line.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        if end > line.location, text.character(at: end - 1) == 0x0D { end -= 1 }
        let content = text.substring(with: NSRange(location: line.location, length: end - line.location))
        guard let item = parse(content) else { return nil }
        let textStart = line.location + item.prefixLength
        // In the marker: an ordinary newline, which opens a line above.
        guard caret >= textStart else { return nil }
        let rest = content.utf16.count > item.prefixLength
            ? (content as NSString).substring(from: item.prefixLength) : ""

        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item ends the list — or this level of it.
            let prefixRange = NSRange(location: line.location, length: end - line.location)
            if let parent = parentItem(of: item, before: line.location, in: text) {
                let outdented = parent.container + parent.indent + nextMarker(after: parent)
                    + parent.spacing + (item.task.isEmpty ? "" : "[ ] ")
                return Edit(range: prefixRange, replacement: outdented,
                            caret: line.location + (outdented as NSString).length)
            }
            // Out of the list: a blank line after it — a quote's own blank
            // line inside a quote — unless one is there already.
            let kept = item.container
            let previousIsBlank = line.location == 0 || {
                let previous = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
                let content = text.substring(with: previous).trimmingCharacters(in: .newlines)
                return content.trimmingCharacters(in: .whitespaces) == kept.trimmingCharacters(in: .whitespaces)
            }()
            let replacement = previousIsBlank
                ? kept
                : kept.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n" + kept
            return Edit(range: prefixRange, replacement: replacement,
                        caret: line.location + (replacement as NSString).length)
        }

        let next = item.container + item.indent + nextMarker(after: item) + item.spacing
            + (item.task.isEmpty ? "" : "[ ] ")
        // Split at the caret; spaces the caret leaves at the start of the new
        // item belong to the marker's spacing, not to the text.
        var tailStart = caret
        while tailStart < end, text.character(at: tailStart) == 0x20 { tailStart += 1 }
        let replacement = "\n" + next
        return Edit(range: NSRange(location: caret, length: tailStart - caret), replacement: replacement,
                    caret: caret + (replacement as NSString).length)
    }

    /// The marker the item after `item` takes: the same bullet, or the next
    /// number with the same delimiter.
    static func nextMarker(after item: Item) -> String {
        guard let number = item.number else { return item.bullet }
        return String(number + 1) + item.delimiter
    }

    /// The nearest item above `lineStart` that `item` is nested in — the first
    /// list line, going up, indented less than it in the same container —
    /// or `nil` when `item` is at the list's own margin.
    static func parentItem(of item: Item, before lineStart: Int, in text: NSString) -> Item? {
        guard !item.indent.isEmpty else { return nil }
        var cursor = lineStart
        var scanned = 0
        while cursor > 0, scanned < 500 {
            let previous = text.lineRange(for: NSRange(location: cursor - 1, length: 0))
            cursor = previous.location
            scanned += 1
            let line = text.substring(with: previous).trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let candidate = parse(line) else {
                // A line of an item's own text, indented under it: keep going.
                if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
                return nil
            }
            guard candidate.container == item.container else { return nil }
            if candidate.indent.count < item.indent.count { return candidate }
        }
        return nil
    }

    /// A list item's first line, read up to its text — `nil` when `line` is
    /// not one.
    static func parse(_ line: String) -> Item? {
        let units = Array(line.utf16)
        var index = 0
        // Quote markers, and the spaces around them.
        var containerEnd = 0
        while true {
            var probe = index
            while probe < units.count, probe - index < 3, units[probe] == 0x20 { probe += 1 }
            guard probe < units.count, units[probe] == 0x3E else { break }   // '>'
            probe += 1
            if probe < units.count, units[probe] == 0x20 { probe += 1 }
            index = probe
            containerEnd = probe
        }
        // Indent: spaces and tabs.
        let indentStart = index
        while index < units.count, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
        let indentEnd = index
        guard index < units.count else { return nil }
        // The marker.
        var bulletEnd = index
        var delimiter = ""
        let first = units[index]
        if first == 0x2D || first == 0x2A || first == 0x2B {          // - * +
            bulletEnd = index + 1
        } else {
            while bulletEnd < units.count, bulletEnd - index < 9,
                  units[bulletEnd] >= 0x30, units[bulletEnd] <= 0x39 { bulletEnd += 1 }
            guard bulletEnd > index, bulletEnd < units.count,
                  units[bulletEnd] == 0x2E || units[bulletEnd] == 0x29 else { return nil }   // . )
            delimiter = String(utf16CodeUnits: [units[bulletEnd]], count: 1)
        }
        let markerEnd = bulletEnd + (delimiter.isEmpty ? 0 : 1)
        // At least one space or tab after the marker — or the end of the line,
        // which is an empty item.
        var spacingEnd = markerEnd
        while spacingEnd < units.count, units[spacingEnd] == 0x20 || units[spacingEnd] == 0x09 { spacingEnd += 1 }
        guard spacingEnd > markerEnd || markerEnd == units.count else { return nil }
        // A thematic break (`- - -`, `***`) is not an item.
        if delimiter.isEmpty, isThematicBreak(units[indentEnd...]) { return nil }
        // A task box.
        var taskEnd = spacingEnd
        if spacingEnd + 2 < units.count, units[spacingEnd] == 0x5B,                   // [
           [0x20, 0x78, 0x58].contains(units[spacingEnd + 1]), units[spacingEnd + 2] == 0x5D,  // ' ' x X, ]
           spacingEnd + 3 == units.count || units[spacingEnd + 3] == 0x20 {
            taskEnd = min(units.count, spacingEnd + 4)
        }
        func text(_ from: Int, _ to: Int) -> String {
            String(utf16CodeUnits: Array(units[from..<to]), count: to - from)
        }
        let spacing = spacingEnd > markerEnd ? text(markerEnd, spacingEnd) : " "
        return Item(container: text(0, containerEnd) + text(containerEnd, indentStart),
                    indent: text(indentStart, indentEnd),
                    bullet: text(index, bulletEnd),
                    delimiter: delimiter,
                    spacing: spacing,
                    task: taskEnd > spacingEnd ? text(spacingEnd, taskEnd) : "",
                    prefixLength: taskEnd)
    }

    /// Three or more of one of `-`, `*`, `_`, and nothing else but spaces.
    private static func isThematicBreak(_ units: ArraySlice<UInt16>) -> Bool {
        guard let first = units.first, first == 0x2D || first == 0x2A || first == 0x5F else { return false }
        var count = 0
        for unit in units {
            if unit == first { count += 1 } else if unit != 0x20 && unit != 0x09 { return false }
        }
        return count >= 3
    }
}

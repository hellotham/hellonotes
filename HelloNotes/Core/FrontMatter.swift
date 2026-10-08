//
//  FrontMatter.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation
import MarkdownCore

/// A typed YAML front-matter property. Types are inferred on parse and drive
/// the editor UI; a small, pragmatic subset of YAML (not a full parser).
nonisolated struct Property: Identifiable, Equatable {
    nonisolated enum Kind: Equatable { case text, number, checkbox, date, list }

    /// A row's identity in the Properties panel: its key, which front matter
    /// holds once — a key written twice by hand is told apart by where it
    /// stands (`FrontMatter.properties(in:)`). It was a fresh `UUID` on every
    /// parse, so every row became a new one whenever the note changed, and
    /// SwiftUI tore down the field being typed in.
    var id: String
    var key: String
    var kind: Kind
    var text: String        // text / number / date
    var bool: Bool          // checkbox
    var items: [String]     // list

    init(key: String, kind: Kind, text: String, bool: Bool, items: [String], id: String? = nil) {
        self.id = id ?? key
        self.key = key
        self.kind = kind
        self.text = text
        self.bool = bool
        self.items = items
    }
}

/// Parse and serialize a note's leading `---` YAML front matter into typed
/// ``Property`` values, and splice edited properties back into a document.
nonisolated enum FrontMatter {

    // MARK: - Parse

    /// The typed properties in `text`'s front matter (empty if there is none).
    static func properties(in text: String) -> [Property] {
        guard let block = block(in: text) else { return [] }
        return entries(from: block.lines).map(\.property)
    }

    /// A property, and the lines of the block it was read from — which a change
    /// to it rewrites, and all a change to it rewrites.
    private struct Entry {
        let property: Property
        let lines: Range<Int>
    }

    /// The typed properties in the lines between a block's fences, each with
    /// the lines it came from.
    ///
    /// A key's lines are its own and every line its value goes on over: a
    /// block list's items, and the lines indented deeper than the key that
    /// carry its value on — a `|` or `>` block's text, a long value wrapped
    /// onto the next line, a flow list broken across two. A change to the key
    /// writes them all again and a removal takes them all; counted as the
    /// key's line alone, the rest would stay behind as lines of nothing, which
    /// YAML reads into whatever key is above them. The value reads as one
    /// line — as the panel shows a value, and as the app writes one.
    ///
    /// A comment is not a property, whatever it says: a `# …` line with a colon
    /// in it was read as a key named `# …`, and offered in the panel as one.
    /// And a line of a file saved with CRLF endings ends in a CR, which is not
    /// part of its value.
    private static func entries(from lines: [String]) -> [Entry] {
        var result: [Entry] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard !isComment(line), let colon = line.firstIndex(of: ":"), !isListItem(line) else { index += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed(String(line[line.index(after: colon)...]))
            guard !key.isEmpty else { index += 1; continue }
            let depth = indentation(of: line)
            let property: Property
            let end: Int
            if isBlockScalarHeader(rawValue) {
                // Everything deeper is the block's text, whatever it holds: a
                // `Note: …` line in it is not a key.
                end = continuation(of: lines, from: index + 1, deeperThan: depth) { _ in true }
                let text = lines[(index + 1)..<end].map(trimmed).filter { !$0.isEmpty }.joined(separator: " ")
                property = Property(key: key, kind: .text, text: text, bool: false, items: [])
            } else if rawValue.isEmpty, let list = blockList(in: lines, from: index + 1) {
                end = list.end
                // Nothing but bare `-` items is no list, as before.
                property = Property(key: key, kind: list.items.isEmpty ? .text : .list,
                                    text: "", bool: false, items: list.items)
            } else {
                // YAML folds a value's deeper lines into it with a space. A
                // deeper `key: value` is a key of its own — read flat, as the
                // panel always has.
                end = continuation(of: lines, from: index + 1, deeperThan: depth) {
                    !isComment($0) && !isMappingEntry($0)
                }
                let raw = ([rawValue] + lines[(index + 1)..<end].map(trimmed)).filter { !$0.isEmpty }
                property = typed(key: key, raw: raw.joined(separator: " "))
            }
            result.append(Entry(property: property, lines: index..<end))
            index = end
        }
        return distinguishingRepeats(result)
    }

    /// A value read as the type it is written as.
    private static func typed(key: String, raw: String) -> Property {
        if raw.hasPrefix("[") {
            let inner = raw.dropFirst().dropLast(raw.hasSuffix("]") ? 1 : 0)
            let items = inner.split(separator: ",").map { scalar(String($0)) }.filter { !$0.isEmpty }
            return Property(key: key, kind: .list, text: "", bool: false, items: items)
        }
        if raw == "true" || raw == "false" {
            return Property(key: key, kind: .checkbox, text: "", bool: raw == "true", items: [])
        }
        if isDate(raw) { return Property(key: key, kind: .date, text: scalar(raw), bool: false, items: []) }
        if isNumber(raw) { return Property(key: key, kind: .number, text: raw, bool: false, items: []) }
        return Property(key: key, kind: .text, text: scalar(raw), bool: false, items: [])
    }

    /// The `- item` lines of a block list starting at `start` — with the blank
    /// lines and comments between them, and a line indented under an item
    /// carrying its text on — and the line after the last of them; `nil` when
    /// no item follows.
    private static func blockList(in lines: [String], from start: Int) -> (items: [String], end: Int)? {
        var raws: [String] = []
        var itemDepth = 0
        var end = start
        var j = start
        while j < lines.count {
            let line = lines[j]
            if isListItem(line) {
                raws.append(String(trimmed(line).dropFirst()))
                itemDepth = indentation(of: line)
            } else if isBlank(line) || isComment(line) {
                // The list's only if an item follows.
                j += 1
                continue
            } else if !raws.isEmpty, indentation(of: line) > itemDepth, !isMappingEntry(line) {
                raws[raws.count - 1] += " " + trimmed(line)
            } else {
                break
            }
            j += 1
            end = j
        }
        guard !raws.isEmpty else { return nil }
        // A bare `-` is an empty item, and an empty item is none.
        return (raws.map(scalar).filter { !$0.isEmpty }, end)
    }

    /// The line after the last of those from `start` that carry a value on:
    /// indented deeper than its key, at `depth`, and accepted by `carriesOn` —
    /// with the blank lines between them, but not the blank lines after them,
    /// which stay between keys.
    private static func continuation(of lines: [String], from start: Int, deeperThan depth: Int,
                                     where carriesOn: (String) -> Bool) -> Int {
        var end = start
        var j = start
        while j < lines.count {
            let line = lines[j]
            if isBlank(line) { j += 1; continue }
            guard indentation(of: line) > depth, carriesOn(line) else { break }
            j += 1
            end = j
        }
        return end
    }

    /// `|` or `>`, with its chomping and indentation indicators (`|-`, `>+`,
    /// `|2`) and perhaps a comment: the value is the block of text below.
    private static func isBlockScalarHeader(_ value: String) -> Bool {
        value.range(of: #"^[|>][1-9+-]{0,2}(\s+#.*)?$"#, options: .regularExpression) != nil
    }

    /// A key written twice is two rows: each repeat takes its place among the
    /// repeats into its identity, after a colon — which no key can hold.
    private static func distinguishingRepeats(_ entries: [Entry]) -> [Entry] {
        var seen: [String: Int] = [:]
        return entries.map { entry in
            var property = entry.property
            let repeats = seen[property.key, default: 0]
            seen[property.key] = repeats + 1
            if repeats > 0 { property.id = "\(property.key):\(repeats)" }
            return Entry(property: property, lines: entry.lines)
        }
    }

    // MARK: - Serialize

    /// Render properties as a YAML front-matter block (without the surrounding
    /// document), or an empty string when there are no properties — the
    /// panel's own style, used where there is no block to keep.
    static func render(_ properties: [Property]) -> String {
        guard !properties.isEmpty else { return "" }
        return (["---"] + properties.flatMap { lines(for: $0) } + ["---"]).joined(separator: "\n") + "\n"
    }

    /// Return `text` with its front matter replaced by `properties` (inserting a
    /// block if there was none, or removing it when `properties` is empty) —
    /// rewriting only the lines of the keys that changed (`splicing`).
    static func applying(_ properties: [Property], to text: String) -> String {
        splicing(properties, into: text, replacing: block(in: text))
    }

    /// `applying`, or `nil` when `properties` are the values `text` already
    /// holds. A field in the Properties panel hands its value back unchanged
    /// when it gains focus, and the panel writes what it is handed: rendered
    /// again, that rewrote the person's YAML in the panel's style — and in
    /// Edit replaced the note on screen and cleared its undo — for a tap. It
    /// reads the block once, as `applying` does anyway.
    static func applyingChanges(_ properties: [Property], to text: String) -> String? {
        let block = block(in: text)
        guard properties != (block.map { entries(from: $0.lines).map(\.property) } ?? []) else { return nil }
        return splicing(properties, into: text, replacing: block)
    }

    /// `properties` written into `text`, **a key at a time**.
    ///
    /// It rendered the whole block again in the panel's style whenever any key
    /// changed, so every key nobody touched changed shape: `tags: [tour]`
    /// became a block list, quoting chosen by hand went, and blank lines and
    /// comments were dropped — the first property added to a note rewrote all
    /// of it. Now each property keeps the lines it was read from unless it
    /// changed. A changed one is written in its place, at its indentation, and
    /// a list in the style it was written in; a removed one takes its lines
    /// with it; an added one goes after the last key, in the panel's style.
    /// Comments, blank lines, key order and line endings are the file's.
    private static func splicing(_ properties: [Property], into text: String, replacing block: Block?) -> String {
        guard let block else { return render(properties) + text }
        let body = String(text[block.bodyStart...])
        // No key left is no front matter at all: the block goes.
        guard !properties.isEmpty else { return body }
        var lines: [String] = []
        var cursor = 0
        var afterLastKey: Int?
        // Which of `properties` no line of the block holds yet — matched by
        // identity, and in order, so a key the panel adds is never taken for
        // one the block already has.
        var unwritten = Array(properties.indices)
        for entry in entries(from: block.lines) {
            lines += block.lines[cursor..<entry.lines.lowerBound]
            cursor = entry.lines.upperBound
            // Removed: its lines go with it.
            guard let match = unwritten.firstIndex(where: { properties[$0].id == entry.property.id }) else { continue }
            let property = properties[unwritten.remove(at: match)]
            let original = block.lines[entry.lines]
            lines += property == entry.property
                ? Array(original)
                : Self.lines(for: property, replacing: original).map { $0 + lineEnding(of: original.first) }
            afterLastKey = lines.count
        }
        // Added: after the last key, ahead of anything after it.
        let added = unwritten.flatMap { Self.lines(for: properties[$0]) }.map { $0 + lineEnding(of: block.opening) }
        lines.insert(contentsOf: added, at: afterLastKey ?? lines.count)
        lines += block.lines[cursor...]
        return ([block.opening] + lines + [block.closing]).joined(separator: "\n")
            + (block.closedByNewline ? "\n" : "") + body
    }

    /// The lines `property` is written as: the panel's style — a list as a
    /// block list, a value quoted where YAML would read it as something else
    /// (`quoteIfNeeded`) — except that a key written again in place of
    /// `original`, the lines it was read from, keeps their indentation, and a
    /// list keeps the style it was written in: a flow list stays one, unless
    /// an item holds a comma, which the flow form cannot read back.
    private static func lines(for property: Property, replacing original: ArraySlice<String>? = nil) -> [String] {
        let first = original?.first.map { $0.trimmingCharacters(in: .newlines) }
        let indent = first.map(leadingWhitespace) ?? ""
        let key = indent + property.key
        switch property.kind {
        case .checkbox:
            return ["\(key): \(property.bool ? "true" : "false")"]
        case .number:
            return ["\(key): \(property.text)"]
        case .text, .date:
            return ["\(key): \(quoteIfNeeded(property.text))"]
        case .list:
            guard !property.items.isEmpty else { return ["\(key): []"] }
            if let first, isFlowList(first), !property.items.contains(where: { $0.contains(",") }) {
                return ["\(key): [\(property.items.map(flowItem).joined(separator: ", "))]"]
            }
            let itemIndent = original?.dropFirst().first(where: isListItem).map(leadingWhitespace) ?? indent + "  "
            return ["\(key):"] + property.items.map { "\(itemIndent)- \(quoteIfNeeded($0))" }
        }
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func indentation(of line: String) -> Int { leadingWhitespace(line).count }

    /// A CR where the line it replaces, or joins, has one — a file's line
    /// endings are the file's.
    private static func lineEnding(of line: String?) -> String {
        line?.hasSuffix("\r") == true ? "\r" : ""
    }

    /// `key: [a, b]`.
    private static func isFlowList(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    /// An item of a flow list, quoted when it would otherwise be read as
    /// something else — or end the list, or open another inside it.
    private static func flowItem(_ item: String) -> String {
        item.contains(where: { "[]{}".contains($0) }) ? quote(item) : quoteIfNeeded(item)
    }

    /// Where the body begins, in UTF-16 units — `NSRange`'s, a caret's — or 0
    /// when there is no front matter. Reads the front matter only.
    static func bodyOffset(in text: String) -> Int {
        guard let block = block(in: text) else { return 0 }
        return text.utf16.distance(from: text.startIndex, to: block.bodyStart)
    }

    /// The document body with any leading front-matter block removed.
    static func body(of text: String) -> String {
        if let block = block(in: text) {
            return String(text[block.bodyStart...])
        }
        return text
    }

    // MARK: - Private

    private struct Block {
        let lines: [String]        // lines between the fences
        let bodyStart: String.Index // index in the original text where the body (after closing ---) begins
        let opening: String        // the fence lines as written — a CR, trailing spaces —
        let closing: String        // so a block written back is the file's where unchanged
        let closedByNewline: Bool  // whether a newline follows the closing fence
    }

    /// Locate the leading `---`…`---` block, returning its inner lines and where
    /// the body starts.
    ///
    /// **A line at a time from the top, and no further than the closing
    /// fence** — the block is a few lines and the note can be megabytes. It
    /// split the whole note into lines and then counted its characters to find
    /// where the body began: a pass over all of it, on the main actor, every
    /// time the Properties panel redrew (1.3 million reads of a 165 KB note's
    /// bridged text, against 554 for the front matter alone). And counting was
    /// wrong: a line is split at `\n`, but `\r\n` is one `Character`, so each
    /// CRLF line inside the block put the body's start a character late, and a
    /// property written back cut the first letter off the body. The index after
    /// the closing fence's newline is where the body starts, whatever the lines
    /// hold.
    private static func block(in text: String) -> Block? {
        let scalars = text.unicodeScalars
        /// The line from `start` — split at `\n` alone, as before — and where
        /// the next line begins (`nil` when this one ends the note).
        func line(from start: String.Index) -> (text: String, next: String.Index?) {
            guard let newline = scalars[start...].firstIndex(of: "\n") else {
                return (String(scalars[start...]), nil)
            }
            return (String(scalars[start..<newline]), scalars.index(after: newline))
        }
        // A fence's CR, in a file saved with CRLF endings, as `BlockParser`
        // allows it — or a CRLF note's front matter folds in the editor and is
        // not front matter here: no properties, and a block added above it.
        func isFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }

        let opening = line(from: text.startIndex)
        guard isFence(opening.text), var next = opening.next else { return nil }
        var inner: [String] = []
        // **No further than the editor looks** (`BlockParser.frontMatterSearchLimit`):
        // a closing fence after that is not front matter's, and a note that
        // opens with a rule and never closes one was read to its end here, on
        // the main actor, at each pause in typing with Properties showing
        // (implemented.md §51.36).
        while inner.count + 1 < BlockParser.frontMatterSearchLimit {
            let current = line(from: next)
            if isFence(current.text) {
                // Two `---` lines are not front matter on their own — the block
                // has to carry at least one `key:` property, which is the same
                // test `BlockParser` applies so the editor folds exactly what
                // the preview strips. Without it a note that opened with a
                // horizontal rule had everything down to its next rule treated
                // as metadata: concealed in Edit, and deleted outright from
                // Preview by `body(of:)`.
                guard inner.contains(where: isMappingEntry) else { return nil }
                return Block(lines: inner, bodyStart: current.next ?? text.endIndex,
                             opening: opening.text, closing: current.text, closedByNewline: current.next != nil)
            }
            inner.append(current.text)
            guard let after = current.next else { return nil }   // never closed
            next = after
        }
        return nil   // not closed where the editor looks for it
    }

    /// `key:` or `key: value` — YAML's mapping entry, and nothing else.
    ///
    /// The colon must end the line or be followed by a space, or `12:30 standup`
    /// and a bare URL both count; a leading `#` is a YAML comment (and how
    /// `## Meeting notes` starts) and a leading `-` a sequence item, so neither
    /// can be the entry that proves the block is a mapping. Kept in step with
    /// `BlockParser.isMappingEntry` — the two answer the same question for the
    /// same document, one for the fold and one for the Properties panel.
    private static func isMappingEntry(_ line: String) -> Bool {
        // Trailing newlines go too: `components(separatedBy: "\n")` leaves the
        // CR of a CRLF file on the end of every line, and `key:\r` would fail
        // the "colon at end of line" test on a file saved on Windows.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard let first = trimmed.first, first != "#", first != "-" else { return false }
        guard let colon = trimmed.firstIndex(of: ":"), colon > trimmed.startIndex else { return false }
        let after = trimmed.index(after: colon)
        return after == trimmed.endIndex || trimmed[after] == " " || trimmed[after] == "\t"
    }

    private static func isListItem(_ line: String) -> Bool {
        let line = trimmed(line)
        return line.hasPrefix("- ") || line == "-"
    }

    private static func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func isBlank(_ line: String) -> Bool { trimmed(line).isEmpty }
    private static func isComment(_ line: String) -> Bool { trimmed(line).hasPrefix("#") }

    private static func isDate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isNumber(_ value: String) -> Bool {
        Double(value) != nil
    }

    private static func scalar(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\"", "'"] where s.hasPrefix(quote) && s.hasSuffix(quote) && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
            // Undo the escaping `quoteIfNeeded` applies. Without this the pair
            // is not a round trip: a value containing a quote gains a backslash
            // every time the block is rewritten.
            if quote == "\"" {
                s = s.replacingOccurrences(of: "\\\"", with: "\"")
                     .replacingOccurrences(of: "\\\\", with: "\\")
            }
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// YAML indicator characters: a value *starting* with one of these is read
    /// as structure rather than text.
    ///
    /// `[` is the one that matters here and it is not hypothetical. A related
    /// link is written `- [[Some Note]]`, and unquoted that is a nested flow
    /// sequence, not a string — so the value would not survive its own round
    /// trip, and every other tool reading the vault (Obsidian included) would
    /// see something the author never wrote.
    private static let yamlIndicators: Set<Character> = [
        "[", "]", "{", "}", ",", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`", "-", "?",
    ]

    private static func quoteIfNeeded(_ value: String) -> String {
        // Quote values that would otherwise change type or break the line.
        if value.isEmpty { return "\"\"" }
        if value == "true" || value == "false" || Double(value) != nil
            || value.contains(":") || value.contains("#")
            || value.first.map(yamlIndicators.contains) == true
            || value != value.trimmingCharacters(in: .whitespaces) {
            return quote(value)
        }
        return value
    }

    /// `value` in double quotes, with any embedded double quote escaped so the
    /// quoting cannot be ended early by the value itself.
    private static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

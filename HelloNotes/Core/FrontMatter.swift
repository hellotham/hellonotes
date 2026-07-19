//
//  FrontMatter.swift
//  HelloNotes
//
//  Created by Chris Tham on 11/7/2026.
//

import Foundation

/// A typed YAML front-matter property. Types are inferred on parse and drive
/// the editor UI; a small, pragmatic subset of YAML (not a full parser).
nonisolated struct Property: Identifiable, Equatable {
    nonisolated enum Kind: Equatable { case text, number, checkbox, date, list }

    var id = UUID()
    var key: String
    var kind: Kind
    var text: String        // text / number / date
    var bool: Bool          // checkbox
    var items: [String]     // list
}

/// Parse and serialize a note's leading `---` YAML front matter into typed
/// ``Property`` values, and splice edited properties back into a document.
nonisolated enum FrontMatter {

    // MARK: - Parse

    /// The typed properties in `text`'s front matter (empty if there is none).
    static func properties(in text: String) -> [Property] {
        guard let block = block(in: text) else { return [] }
        let lines = block.lines
        var result: [Property] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let colon = line.firstIndex(of: ":"), !isListItem(line) else { index += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { index += 1; continue }

            if rawValue.isEmpty {
                // Possibly a block list on the following `- item` lines.
                var items: [String] = []
                var j = index + 1
                while j < lines.count, isListItem(lines[j]) {
                    let item = scalar(String(lines[j].trimmingCharacters(in: .whitespaces).dropFirst()))
                    if !item.isEmpty { items.append(item) }   // skip bare `-` (empty item)
                    j += 1
                }
                if items.isEmpty {
                    result.append(Property(key: key, kind: .text, text: "", bool: false, items: []))
                } else {
                    result.append(Property(key: key, kind: .list, text: "", bool: false, items: items))
                    index = j
                    continue
                }
            } else if rawValue.hasPrefix("[") {
                let inner = rawValue.dropFirst().dropLast(rawValue.hasSuffix("]") ? 1 : 0)
                let items = inner.split(separator: ",").map { scalar(String($0)) }.filter { !$0.isEmpty }
                result.append(Property(key: key, kind: .list, text: "", bool: false, items: items))
            } else if rawValue == "true" || rawValue == "false" {
                result.append(Property(key: key, kind: .checkbox, text: "", bool: rawValue == "true", items: []))
            } else if isDate(rawValue) {
                result.append(Property(key: key, kind: .date, text: scalar(rawValue), bool: false, items: []))
            } else if isNumber(rawValue) {
                result.append(Property(key: key, kind: .number, text: rawValue, bool: false, items: []))
            } else {
                result.append(Property(key: key, kind: .text, text: scalar(rawValue), bool: false, items: []))
            }
            index += 1
        }
        return result
    }

    // MARK: - Serialize

    /// Render properties as a YAML front-matter block (without the surrounding
    /// document), or an empty string when there are no properties.
    static func render(_ properties: [Property]) -> String {
        guard !properties.isEmpty else { return "" }
        var out = "---\n"
        for property in properties {
            switch property.kind {
            case .checkbox:
                out += "\(property.key): \(property.bool ? "true" : "false")\n"
            case .list:
                if property.items.isEmpty {
                    out += "\(property.key): []\n"
                } else {
                    out += "\(property.key):\n"
                    for item in property.items { out += "  - \(quoteIfNeeded(item))\n" }
                }
            case .number:
                out += "\(property.key): \(property.text)\n"
            case .text, .date:
                out += "\(property.key): \(quoteIfNeeded(property.text))\n"
            }
        }
        out += "---\n"
        return out
    }

    /// Return `text` with its front matter replaced by `properties` (inserting a
    /// block if there was none, or removing it when `properties` is empty).
    static func applying(_ properties: [Property], to text: String) -> String {
        let body: String
        if let block = block(in: text) {
            body = String(text[block.bodyStart...])
        } else {
            body = text
        }
        let rendered = render(properties)
        if rendered.isEmpty { return body }
        // Ensure exactly one blank line isn't forced; keep body as-is.
        return rendered + body
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
    }

    /// Locate the leading `---`…`---` block, returning its inner lines and where
    /// the body starts.
    private static func block(in text: String) -> Block? {
        let allLines = text.components(separatedBy: "\n")
        guard allLines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var closing: Int? = nil
        for i in 1..<allLines.count where allLines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closing = i
            break
        }
        guard let closingIndex = closing else { return nil }
        let inner = Array(allLines[1..<closingIndex])

        // Body starts after the closing fence line (and its trailing newline).
        var consumed = 0
        for i in 0...closingIndex { consumed += allLines[i].count + (i < allLines.count - 1 ? 1 : 0) }
        let bodyStart = text.index(text.startIndex, offsetBy: min(consumed, text.count))
        return Block(lines: inner, bodyStart: bodyStart)
    }

    private static func isListItem(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
            || line.trimmingCharacters(in: .whitespaces) == "-"
    }

    private static func isDate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isNumber(_ value: String) -> Bool {
        Double(value) != nil
    }

    private static func scalar(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where s.hasPrefix(quote) && s.hasSuffix(quote) && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        // Quote values that would otherwise change type or break the line.
        if value.isEmpty { return "\"\"" }
        if value == "true" || value == "false" || Double(value) != nil || value.contains(":") || value.contains("#") {
            return "\"\(value)\""
        }
        return value
    }
}

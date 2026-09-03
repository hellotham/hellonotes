//
//  AnswerMarkdown.swift
//  HelloNotes
//
//  What a model writes is Markdown. Draw it as Markdown.
//
//  Ask Your Library rendered its answer with a bare `Text(answer)`, so a reply
//  reading `**Creating Links:** Typing `[[` allows you to…` appeared on screen
//  exactly like that — asterisks, backticks and all. It is the app's flagship
//  answer surface and it was showing its own source. The Assistant did better
//  with `Text(LocalizedStringKey(text))`, which is the usual SwiftUI trick for
//  inline Markdown, and pays for it twice: that path is `.inlineOnly`, so it
//  **discards every line break** (a bulleted answer becomes one paragraph), and
//  it runs arbitrary model output through localisation lookup, where a reply
//  that happens to match a key would be silently replaced by the translation.
//
//  So: one renderer, used by both.
//
//  Deliberately *not* the editor's Markdown engine. `MarkdownCore` +
//  `StyleApplier` exist to lay out a document in a TextKit view with a box
//  model and a parity harness behind them; an answer bubble needs bold, code,
//  links, bullets and line breaks. Line-based keeps it honest about what it
//  supports rather than half-implementing a document renderer.
//

import Foundation
import SwiftUI

enum AnswerMarkdown {

    /// A model answer as attributed text: inline Markdown within each line,
    /// list markers as real bullets, headings bold, fenced code monospaced,
    /// and the line structure kept.
    static func attributed(_ markdown: String) -> AttributedString {
        var out = AttributedString()
        var inFence = false

        for (i, raw) in markdown.components(separatedBy: "\n").enumerated() {
            if i > 0 { out += AttributedString("\n") }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                // The fence itself draws nothing — it is punctuation, and a
                // visible ``` is the whole complaint this file exists about.
                inFence.toggle()
                continue
            }
            if inFence {
                var line = AttributedString(raw)
                line.font = .system(.body, design: .monospaced)
                out += line
                continue
            }
            out += line(raw, trimmed: trimmed)
        }
        return out
    }

    // MARK: -

    private static func line(_ raw: String, trimmed: String) -> AttributedString {
        // Heading: `#`…`######`, one space, text.
        if let hashes = headingLevel(trimmed) {
            let text = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
            var line = inline(text)
            // One step of emphasis for every heading level would give a chat
            // bubble six type sizes; two is enough to read as a heading.
            line.font = hashes <= 2 ? .title3.bold() : .headline
            return line
        }
        // Blockquote.
        if trimmed.hasPrefix("> ") {
            var line = inline(String(trimmed.dropFirst(2)))
            line.foregroundColor = .secondary
            return line
        }
        // List item — bullet or ordered. The indent is kept as written so a
        // nested list still reads as nested.
        if let (indent, marker, rest) = listItem(raw) {
            var line = AttributedString(indent + marker + " ")
            line.foregroundColor = .secondary
            return line + inline(rest)
        }
        return inline(raw)
    }

    /// `#` count for a heading line, or nil. Requires the space: `#tag` at the
    /// start of a line is a tag, not an H1.
    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), trimmed.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    /// `(leading whitespace, bullet to draw, the rest)` for a list line.
    private static func listItem(_ raw: String) -> (String, String, String)? {
        let indent = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
        let body = raw.dropFirst(indent.count)
        if let first = body.first, "-*+".contains(first), body.dropFirst().hasPrefix(" ") {
            return (indent, "•", String(body.dropFirst(2)))
        }
        // `1.` / `12)` — keep the writer's number; renumbering an answer would
        // be editing it.
        let digits = body.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")", after.dropFirst().hasPrefix(" ") {
                return (indent, "\(digits)\(sep)", String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// Inline Markdown only — bold, italic, code, links — with the whitespace
    /// kept. Falls back to the literal text, because an answer that fails to
    /// parse must still be readable: showing nothing would be worse than
    /// showing asterisks.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

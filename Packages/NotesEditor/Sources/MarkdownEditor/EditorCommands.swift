//
//  EditorCommands.swift
//  MarkdownEditor
//
//  Formatting and AI edit commands, implemented on the text view so every
//  mutation flows through shouldChangeText → replaceCharacters →
//  didChangeText: full undo registration, selection preservation, and the
//  document's incremental reparse/restyle — the same path typing takes.
//

#if canImport(AppKit)
import AppKit
import MarkdownCore

/// A formatting command the host can send (Format menu, toolbar, AI).
public enum EditorFormatCommand: Sendable, Equatable {
    case bold, italic, strikethrough, highlight, inlineCode
    case heading(Int)          // 1…6; same level again removes the heading
    case blockquote
    case unorderedList
    case orderedList
}

extension MarkdownTextView {

    // MARK: - Programmatic edits (the one true mutation path)

    /// Replace `range` with `text`, undoably, moving the caret to the end
    /// of the replacement. This is also the AI seam: Writing-Tools-style
    /// rewrites and provider-driven transforms land through here.
    @discardableResult
    public func performEdit(replacing range: NSRange, with text: String) -> Bool {
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        return true
    }

    // MARK: - Formatting

    public func apply(_ command: EditorFormatCommand) {
        switch command {
        case .bold: toggleInline(marker: "**")
        case .italic: toggleInline(marker: "*")
        case .strikethrough: toggleInline(marker: "~~")
        case .highlight: toggleInline(marker: "==")
        case .inlineCode: toggleInline(marker: "`")
        case .heading(let level): setHeading(level: level)
        case .blockquote: toggleLinePrefix("> ")
        case .unorderedList: toggleLinePrefix("- ")
        case .orderedList: toggleOrderedList()
        }
    }

    /// Wrap the selection in `marker` … `marker`, or unwrap when already
    /// wrapped (inside or immediately around the selection). With an empty
    /// selection, insert a marker pair and park the caret inside.
    private func toggleInline(marker: String) {
        let ns = string as NSString
        let m = marker as NSString
        var sel = selectedRange()

        if sel.length == 0 {
            let insertion = "\(marker)\(marker)"
            guard shouldChangeText(in: sel, replacementString: insertion) else { return }
            textStorage?.replaceCharacters(in: sel, with: insertion)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + m.length, length: 0))
            return
        }

        // Selection includes the markers?
        let inner = ns.substring(with: sel)
        if inner.hasPrefix(marker), inner.hasSuffix(marker), sel.length >= 2 * m.length {
            let stripped = String(inner.dropFirst(marker.count).dropLast(marker.count))
            if performEdit(replacing: sel, with: stripped) {
                setSelectedRange(NSRange(location: sel.location, length: (stripped as NSString).length))
            }
            return
        }
        // Markers immediately around the selection?
        if sel.location >= m.length, sel.location + sel.length + m.length <= ns.length {
            let before = ns.substring(with: NSRange(location: sel.location - m.length, length: m.length))
            let after = ns.substring(with: NSRange(location: sel.location + sel.length, length: m.length))
            if before == marker, after == marker {
                let outer = NSRange(location: sel.location - m.length, length: sel.length + 2 * m.length)
                if performEdit(replacing: outer, with: inner) {
                    setSelectedRange(NSRange(location: outer.location, length: sel.length))
                }
                return
            }
        }
        // Wrap.
        sel = selectedRange()
        let wrapped = "\(marker)\(inner)\(marker)"
        if performEdit(replacing: sel, with: wrapped) {
            setSelectedRange(NSRange(location: sel.location + m.length, length: sel.length))
        }
    }

    /// Set (or toggle off) an ATX heading level on every selected line.
    private func setHeading(level: Int) {
        mapSelectedLines { line in
            let stripped = line.drop(while: { $0 == "#" }).drop(while: { $0 == " " })
            let current = line.prefix(while: { $0 == "#" }).count
            if current == level { return String(stripped) }
            return String(repeating: "#", count: max(1, min(level, 6))) + " " + stripped
        }
    }

    /// Add `prefix` to every selected line, or remove it when every
    /// non-empty selected line already has it.
    private func toggleLinePrefix(_ prefix: String) {
        mapSelectedLines(togglingAll: true) { line in
            if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
            return prefix + line
        }
    }

    private func toggleOrderedList() {
        let ns = string as NSString
        let lines = selectedLineRange()
        let text = ns.substring(with: lines)
        let split = text.components(separatedBy: "\n")
        let allNumbered = split.filter { !$0.isEmpty }.allSatisfy { $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
        var counter = 1
        let mapped = split.map { line -> String in
            guard !line.isEmpty else { return line }
            if allNumbered {
                return line.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression)
            }
            let cleaned = line.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression)
            defer { counter += 1 }
            return "\(counter). \(cleaned)"
        }.joined(separator: "\n")
        performEdit(replacing: lines, with: mapped)
    }

    /// Transform each selected line; preserves the trailing-newline shape.
    private func mapSelectedLines(togglingAll: Bool = false, _ transform: (String) -> String) {
        let ns = string as NSString
        let lines = selectedLineRange()
        let text = ns.substring(with: lines)
        let mapped = text
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : transform($0) }
            .joined(separator: "\n")
        guard mapped != text else { return }
        performEdit(replacing: lines, with: mapped)
    }

    /// The full line range of the selection, without its trailing newline.
    private func selectedLineRange() -> NSRange {
        let ns = string as NSString
        var r = ns.lineRange(for: selectedRange())
        if r.length > 0, ns.character(at: r.location + r.length - 1) == 0x0A { r.length -= 1 }
        return r
    }

    // MARK: - Find & navigation

    /// Select and scroll to the `index`-th match of `query`; returns the
    /// match count (the app's find bar shows it).
    @discardableResult
    public func showMatch(of query: String, index: Int) -> Int {
        guard let document else { return 0 }
        let matches = document.findMatches(of: query)
        guard !matches.isEmpty else { return 0 }
        let target = matches[max(0, min(index, matches.count - 1))]
        setSelectedRange(target)
        reliablyScroll(to: target)
        return matches.count
    }
}
#endif

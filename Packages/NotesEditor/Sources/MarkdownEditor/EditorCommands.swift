//
//  EditorCommands.swift
//  MarkdownEditor
//
//  Formatting and AI edit commands, implemented on the text view so every
//  mutation flows through shouldChangeText → replaceCharacters →
//  didChangeText: full undo registration, selection preservation, and the
//  document's incremental reparse/restyle — the same path typing takes.
//

import Foundation
import MarkdownCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A formatting command the host can send (Format menu, toolbar, AI).
public enum EditorFormatCommand: Sendable, Equatable {
    case bold, italic, strikethrough, highlight, inlineCode
    case heading(Int)          // 1…6; same level again removes the heading
    case blockquote
    case unorderedList
    case orderedList
}

/// What a Markdown formatting command needs from an editor view.
///
/// These commands used to be an extension on `MarkdownTextView` — the *macOS*
/// `NSTextView` — inside a file gated on `canImport(AppKit)`. So iPad had no
/// formatting whatsoever: no bold, no headings, no lists, and nothing to reach
/// them from. The logic never needed a platform, only the text, the selection,
/// and an undoable way to replace a range. Naming those makes the commands
/// shared rather than duplicated, which is what stops the two platforms
/// drifting on what "toggle a heading" means.
@MainActor
public protocol MarkdownFormatting: AnyObject {
    /// The whole document's text.
    var formattingText: String { get }
    /// The current selection.
    func formattingSelection() -> NSRange
    /// Move or extend the selection.
    func setFormattingSelection(_ range: NSRange)
    /// Replace `range` with `text`, undoably, leaving the caret after it.
    @discardableResult
    func performEdit(replacing range: NSRange, with text: String) -> Bool
    /// Scroll so the character at `offset` sits at the *top* of the viewport.
    /// A requirement rather than a constrained extension so `showHeading(at:)`
    /// can be written once for every conformer; the two implementations are
    /// `NSTextView`'s and `UITextView`'s, at the bottom of this file.
    func scrollHeadingIntoView(at offset: Int)
    /// The document's blocks, when this view has a parsed one.
    ///
    /// The live editor does — `EditorDocument` keeps `blocks` current through
    /// the splicer, so the n-th heading's range is already known and costs no
    /// parse. The raw-source view does not, and answers `nil`.
    var formattingBlocks: [Block]? { get }
}

public extension MarkdownFormatting {

    /// Put the heading beginning at `offset` at the top of the viewport.
    ///
    /// A **position**, not a query — and one definition, because four surfaces
    /// need it: the live editor and the raw-source pane on each platform. The
    /// outline used to jump by handing the heading's own text to the find
    /// machinery, which lands on the first occurrence of those words anywhere in
    /// the file: the front matter's `title:` line, or any sentence that mentions
    /// them, both of which come *before* the heading. The caller knows exactly
    /// where the heading is; this goes there.
    ///
    /// The selection collapses to the heading's start rather than covering its
    /// text — navigating should leave a caret, not a selection to dismiss.
    func showHeading(at offset: Int) {
        let length = (formattingText as NSString).length
        guard offset >= 0, offset <= length else { return }
        setFormattingSelection(NSRange(location: offset, length: 0))
        scrollHeadingIntoView(at: offset)
    }

    /// Go to the `ordinal`-th heading, resolved against the blocks this view
    /// already has. Returns false when it has none — the raw-source view — so
    /// the caller can fall back to a scan off the main actor.
    ///
    /// **No parse, and nothing stale.** `EditorDocument.blocks` carries absolute
    /// ranges that the splicer keeps in sync with every edit, so this is a walk
    /// over an array that is already correct. That is the whole reason the jump
    /// sends an ordinal rather than an offset: an offset is only true of the
    /// text it was measured against, and keeping one true means re-parsing on
    /// the actor that must never be blocked.
    @discardableResult
    func showHeading(ordinal: Int, title: String) -> Bool {
        guard let blocks = formattingBlocks else { return false }
        let headings = blocks.filter { if case .heading = $0.kind { return true }; return false }
        guard !headings.isEmpty else { return true }

        // The ordinal comes from the outline's parser and this list comes from
        // the editor's; they agree on ordinary documents and this notices when
        // they do not. Either way the destination is a *heading* — the failure
        // mode is landing on the wrong one, never on prose.
        let ns = formattingText as NSString
        func text(of block: Block) -> String {
            ns.substring(with: block.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespaces)
        }
        let target: Block
        if headings.indices.contains(ordinal), text(of: headings[ordinal]) == title {
            target = headings[ordinal]
        } else if let named = headings.first(where: { text(of: $0) == title }) {
            target = named
        } else if headings.indices.contains(ordinal) {
            target = headings[ordinal]
        } else {
            return true
        }
        showHeading(at: target.range.location)
        return true
    }
}

extension MarkdownFormatting {


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
        let ns = formattingText as NSString
        let m = marker as NSString
        var sel = formattingSelection()

        if sel.length == 0 {
            // Insert an empty pair and park the caret between the markers —
            // `performEdit` would leave it after them.
            let insertion = "\(marker)\(marker)"
            guard performEdit(replacing: sel, with: insertion) else { return }
            setFormattingSelection(NSRange(location: sel.location + m.length, length: 0))
            return
        }

        // Selection includes the markers?
        let inner = ns.substring(with: sel)
        if inner.hasPrefix(marker), inner.hasSuffix(marker), sel.length >= 2 * m.length {
            let stripped = String(inner.dropFirst(marker.count).dropLast(marker.count))
            if performEdit(replacing: sel, with: stripped) {
                setFormattingSelection(NSRange(location: sel.location, length: (stripped as NSString).length))
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
                    setFormattingSelection(NSRange(location: outer.location, length: sel.length))
                }
                return
            }
        }
        // Wrap.
        sel = formattingSelection()
        let wrapped = "\(marker)\(inner)\(marker)"
        if performEdit(replacing: sel, with: wrapped) {
            setFormattingSelection(NSRange(location: sel.location + m.length, length: sel.length))
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
        let ns = formattingText as NSString
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
        let ns = formattingText as NSString
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
        let ns = formattingText as NSString
        var r = ns.lineRange(for: formattingSelection())
        if r.length > 0, ns.character(at: r.location + r.length - 1) == 0x0A { r.length -= 1 }
        return r
    }

}

// The conformance, both halves, in one gate.
//
// They used to sit in two files — this one and `MarkdownUITextView.swift` —
// each inside its own one-sided gate, which is how `showMatch(of:index:)` came
// to exist on one editor and not the other. `MarkdownFormatting` keeps the
// members it *declares* in step; `showMatch` is not one of them, so nothing
// failed to compile and every heading jump on the other platform silently did
// nothing. Adjacent, the difference is a diff.
#if canImport(AppKit)
extension MarkdownTextView: MarkdownFormatting {

    /// The live editor's own parse, kept current by the splicer.
    public var formattingBlocks: [Block]? { document?.blocks }

    public var formattingText: String { string }
    public func formattingSelection() -> NSRange { selectedRange() }
    public func setFormattingSelection(_ range: NSRange) { setSelectedRange(range) }

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

#else

extension MarkdownUITextView: MarkdownFormatting {

    /// The live editor's own parse, kept current by the splicer.
    public var formattingBlocks: [Block]? { document?.blocks }

    public var formattingText: String { text ?? "" }
    public func formattingSelection() -> NSRange { selectedRange }
    public func setFormattingSelection(_ range: NSRange) { selectedRange = range }

    /// Replace `range` with `text`, undoably.
    ///
    /// `replace(_:withText:)` rather than poking `textStorage`: it is the
    /// `UITextInput` path, so it registers undo, notifies the delegate, and
    /// therefore reaches the document's incremental reparse — the same route a
    /// keystroke takes. Writing to the storage directly would format the text
    /// and leave the parse, the undo stack and the delegate all behind.
    @discardableResult
    public func performEdit(replacing range: NSRange, with text: String) -> Bool {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end)
        else { return false }
        replace(textRange, withText: text)
        selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        return true
    }

    /// Select and scroll to the `index`-th match of `query`; returns the match
    /// count (the app's find bar shows it).
    ///
    /// This existed only on the AppKit view, and it is not a protocol
    /// requirement, so nothing failed to compile — the four find notifications
    /// simply had no listener here. What that cost was not only the app's own
    /// find bar (iOS has `UIFindInteraction` for that). Heading jumps used to
    /// arrive here too — as a query for the heading's own text, which is how
    /// they landed on the front matter or on prose. They go through
    /// `showHeading(at:)` now and carry a position.
    @discardableResult
    public func showMatch(of query: String, index: Int) -> Int {
        guard let document else { return 0 }
        let matches = document.findMatches(of: query)
        guard !matches.isEmpty else { return 0 }
        let target = matches[max(0, min(index, matches.count - 1))]
        selectedRange = target
        reliablyScroll(to: target)
        return matches.count
    }
}

#endif

#if canImport(UIKit)
import UIKit

public extension MarkdownFormatting where Self: UITextView {

    /// Put the formatting commands where iOS puts editor affordances.
    ///
    /// ## The rule
    ///
    /// **Shown whenever there is focus and a caret — and therefore independent
    /// of the mode.** Preview never gets a caret, so it never shows one.
    ///
    /// That is a property of *where* these live rather than a condition
    /// anything evaluates: an assistant bar belongs to a first responder, so it
    /// exists exactly when something is being typed into. Two earlier attempts
    /// tried to express the rule instead of inheriting it — an accessory (whose
    /// real rule turned out to be "whenever the text view happens to be first
    /// responder", stated nowhere) and then a bar of the app's own gated on
    /// `mode.isEditable`. The second was predictable but redundant: `Preview`
    /// builds a `GFMPreview` and no text view at all, and the other three modes
    /// pass `isEditable`, so "can I type here?" was already answered by the
    /// view tree. `EditorMode.isEditable` was deleted with that bar.
    ///
    /// The case worth checking is the transition, because that is where
    /// "sometimes" bugs live: leaving a *focused* Edit session for Preview tears
    /// the text view down, which resigns first responder, which takes the bar
    /// with it. Verified on device.
    ///
    ///
    /// **iPad: the shortcuts bar** (`inputAssistantItem`) — the floating pill
    /// that carries the keyboard/language selector and the dictation mic. It is
    /// where a person looks for "make this bold", it costs the app no screen
    /// space, it cannot overlap the app's own chrome, and — verified on a
    /// simulator with a hardware keyboard attached, which is the case that
    /// breaks everything else — it appears there too, beside `EN AU` and the
    /// microphone.
    ///
    /// **iPhone: an `inputAccessoryView`**, because the shortcuts bar does not
    /// exist on iPhone; groups set here are simply ignored. That is the native
    /// answer on that idiom, and it is the reason this is a runtime idiom check
    /// rather than a compile-time one — the same binary runs on both.
    ///
    /// The commands are grouped so iOS can collapse them when the pill is
    /// short: a group with a `representativeItem` becomes that single button
    /// when its members do not fit, which is how eleven commands live in a
    /// space that shows four. Grouping by *kind* rather than arbitrarily is
    /// what makes the collapsed form still make sense.
    func installFormattingAssistant() {
        func item(_ symbol: String, _ label: String,
                  _ command: EditorFormatCommand) -> UIBarButtonItem {
            let action = UIAction(image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.apply(command)
            }
            let button = UIBarButtonItem(primaryAction: action)
            // Named, not merely drawn — an SF Symbol is not a label.
            button.accessibilityLabel = label
            return button
        }

        let inline = UIBarButtonItemGroup(
            barButtonItems: [
                item("bold", "Bold", .bold),
                item("italic", "Italic", .italic),
                item("strikethrough", "Strikethrough", .strikethrough),
                item("highlighter", "Highlight", .highlight),
                item("chevron.left.forwardslash.chevron.right", "Code", .inlineCode),
            ],
            representativeItem: UIBarButtonItem(
                image: UIImage(systemName: "bold.italic.underline"), menu: nil))
        inline.representativeItem?.accessibilityLabel = "Text Style"

        let blocks = UIBarButtonItemGroup(
            barButtonItems: [
                item("text.quote", "Blockquote", .blockquote),
                item("list.bullet", "Bulleted List", .unorderedList),
                item("list.number", "Numbered List", .orderedList),
            ],
            representativeItem: UIBarButtonItem(
                image: UIImage(systemName: "list.bullet"), menu: nil))
        blocks.representativeItem?.accessibilityLabel = "Lists"

        let headings = UIBarButtonItemGroup(
            barButtonItems: (1...3).map {
                item("\($0).square", "Heading \($0)", .heading($0))
            },
            representativeItem: UIBarButtonItem(
                image: UIImage(systemName: "textformat.size"), menu: nil))
        headings.representativeItem?.accessibilityLabel = "Headings"

        if UIDevice.current.userInterfaceIdiom == .pad {
            inputAssistantItem.leadingBarButtonGroups = [inline, blocks]
            inputAssistantItem.trailingBarButtonGroups = [headings]
        } else {
            // iPhone has no shortcuts bar. An accessory above the keyboard is
            // the native answer there, and it does not overlap the app's bottom
            // bar because SwiftUI's own keyboard safe area accounts for an
            // accessory view. (An earlier `KeyboardOverlap` measured the
            // keyboard frame by hand; it existed only to compensate for a
            // hand-rolled accessory on *iPad*, which the shortcuts bar replaced,
            // and it is gone.)
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.autoresizingMask = .flexibleWidth
            bar.items = inline.barButtonItems + blocks.barButtonItems
                + headings.barButtonItems
            bar.sizeToFit()
            inputAccessoryView = bar
        }
    }
}
#else

// **No AppKit half, deliberately.**
//
// `inputAssistantItem` and `inputAccessoryView` are UIKit concepts; AppKit has
// neither, and it does not need them. On the Mac these same commands live in
// the Format menu (`AppCommands.swift`) with keyboard shortcuts — ⌘B, ⌘I,
// ⇧⌘7 — permanently visible in the menu bar, which is the affordance that
// platform actually has. The shared half is `MarkdownFormatting` above: both
// platforms apply commands through it, so "toggle a heading" means one thing
// everywhere and only the *route to it* differs.

#endif

// MARK: - Scrolling a heading into view

#if canImport(AppKit)
public extension MarkdownFormatting where Self: NSTextView {
    /// Scroll so the heading sits at the top rather than merely on screen —
    /// `scrollRangeToVisible` does nothing when the target is already visible
    /// at the bottom, which reads as the jump having failed.
    func scrollHeadingIntoView(at offset: Int) {
        guard let layoutManager, let container = textContainer else {
            scrollRangeToVisible(NSRange(location: offset, length: 0)); return
        }
        let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: offset, length: 0),
                                             actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyph, in: container)
        let top = rect.origin.y + textContainerInset.height
        enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: top))
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
    }
}
#else
public extension MarkdownFormatting where Self: UITextView {
    /// See the AppKit twin: top of the viewport, not merely visible.
    func scrollHeadingIntoView(at offset: Int) {
        let range = NSRange(location: offset, length: 0)
        guard let start = position(from: beginningOfDocument, offset: offset),
              let textRange = textRange(from: start, to: start) else {
            scrollRangeToVisible(range); return
        }
        let rect = caretRect(for: textRange.start)
        let top = max(0, min(rect.origin.y - textContainerInset.top,
                             max(0, contentSize.height - bounds.height)))
        setContentOffset(CGPoint(x: 0, y: top), animated: true)
    }
}
#endif

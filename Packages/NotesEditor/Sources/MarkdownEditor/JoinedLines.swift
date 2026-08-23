//
//  JoinedLines.swift
//  MarkdownEditor
//
//  The newline the page does not break at.
//
//  Preview renders with `CMARK_OPT_HARDBREAKS`, so every line ending the
//  writer typed comes back as a `<br>` and the editor's line-for-line layout
//  is right — *except* where cmark has already eaten the newline into a token.
//  Inside a code span, inside a link's `(…)`, inside a raw tag or an HTML
//  comment, a line ending is not a line break: it is a space (or nothing), the
//  construct is one token, and the page draws one line where the editor drew
//  two. Eleven of the spec's examples are that and only that.
//
//  Text substitution is not on the table — the storage IS the document, and
//  the first invariant of this package is that presentation never changes it.
//  What TextKit 2 does allow is a *content element* that spans more of the
//  document than one paragraph: `NSTextContentStorage` asks its delegate for
//  the paragraph at a range, and the delegate may answer with a longer one.
//  That is what happens here. The storage keeps its newline; the element the
//  layout manager is handed has a space in its place, and covers both source
//  lines. Length-preserving, so every offset↔location round-trip stays exact
//  and the caret lands on the source character the reader clicked.
//
//  Three things were measured into this shape and none of them is obvious.
//
//  1. `NSTextParagraph.paragraphContentRange` is documented as "derived from
//     elementRange and attributedString" and is in fact **computed once and
//     kept**: `NSTextContentStorage` assigns `elementRange` the moment the
//     delegate returns, deriving the content and separator ranges from the
//     *source* paragraph, and widening `elementRange` afterwards changes
//     nothing. Selection navigation reads those ranges, so a merged element
//     that only widened `elementRange` laid out perfectly and then clamped
//     every caret at the join: click anywhere in the tail and the insertion
//     point went to the newline. `MergedParagraph` owns all three.
//  2. A paragraph the content storage did **not** create has no paragraph
//     ranges at all (they come back nil), and `NSTextLayoutFragment` crashes
//     laying one out. So the merged element is built inside the delegate
//     callback, where the framework still adopts it, and not anywhere else.
//  3. `NSTextContentStorage` re-asks the delegate when the *storage* says the
//     range changed — not when this file's answer changes. Nothing here needs
//     to force that, because the answer is an attribute on the newline, and it
//     is written by the restyle that would change it, inside the same
//     `beginEditing`/`endEditing`. A join that appeared or vanished without a
//     restyle would keep the old layout, which is why it is an attribute and
//     not a set held on the side.
//

import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// On a `\n`: the page does not break here, so neither does the editor.
///
/// The folded line ending is a **space**, always, because that is what cmark
/// puts there. CommonMark's other rule about code spans — that a content which
/// begins *and* ends with a space loses one at each end — is deliberately not
/// here: it is a rule about a code span's content and not about line endings at
/// all, it applies just as much to `` ` foo ` `` written on one line, and the
/// editor is a space wide at each end of that one today. Two different
/// mechanisms for one rule would be two places for it to drift.
nonisolated let joinedNewlineAttribute = NSAttributedString.Key("hn.joinedNewline")

/// A content element standing for several source lines the page draws as one.
///
/// It exists to own its own ranges. Everything else — the text, the attributes,
/// the paragraph style — comes straight from the storage.
nonisolated final class MergedParagraph: NSTextParagraph {
    nonisolated(unsafe) private var wholeRun: NSTextRange?
    nonisolated(unsafe) private var content: NSTextRange?
    nonisolated(unsafe) private var separator: NSTextRange?

    /// `elementRange` has to be *readable* as the whole run and still
    /// *writable* by the framework, which assigns the source paragraph's range
    /// on the way out of the delegate. Swallowing that write instead of
    /// shadowing it loses whatever bookkeeping the assignment does.
    override var elementRange: NSTextRange? {
        get { wholeRun ?? super.elementRange }
        set { super.elementRange = newValue }
    }
    override var paragraphContentRange: NSTextRange? { content ?? super.paragraphContentRange }
    override var paragraphSeparatorRange: NSTextRange? { separator ?? super.paragraphSeparatorRange }

    func span(_ run: NSTextRange, content: NSTextRange, separator: NSTextRange) {
        self.wholeRun = run
        self.content = content
        self.separator = separator
    }
}

/// Vends the merged elements. One per text view; the content storage's
/// `delegate` is weak, so whoever builds the stack keeps it.
///
/// Stateless on purpose: the whole answer is in the storage, so this cannot
/// disagree with the document, and there is nothing to invalidate.
final class JoinedLineDelegate: NSObject, @preconcurrency NSTextContentStorageDelegate {

    /// The paragraph for `range`, merged with everything joined to it.
    ///
    /// Returning nil is the fast path and the overwhelmingly common one: two
    /// attribute lookups, one at each end of the paragraph, and every note with
    /// no line-crossing construct in it pays exactly that and nothing else.
    /// Measured against the same note with the delegate detached, laying out
    /// 2,400 lines came to 115ms either way.
    func textContentStorage(_ storage: NSTextContentStorage,
                            textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let backing = storage.textStorage else { return nil }
        let text = backing.string as NSString
        let run = joinedRun(containing: range, in: backing, text: text)
        guard run.length != range.length || run.location != range.location else { return nil }

        let merged = NSMutableAttributedString(attributedString: backing.attributedSubstring(from: run))
        var spacing: CGFloat = 0
        var i = 0
        while i < merged.length {
            let absolute = run.location + i
            if backing.attribute(joinedNewlineAttribute, at: absolute, effectiveRange: nil) != nil {
                merged.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
            }
            if let style = backing.attribute(.paragraphStyle, at: absolute,
                                             effectiveRange: nil) as? NSParagraphStyle {
                spacing = max(spacing, style.paragraphSpacing)
            }
            i += 1
        }
        // One box, one bottom margin. `applyBase` parks a block's trailing gap
        // on its **last** line, which is exactly the line that stops existing
        // here, and TextKit reads the merged paragraph's style off its first
        // character — so without this the note lost 16pt under every joined
        // construct while every line of it was still in the right place.
        if let head = merged.length > 0
            ? merged.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil,
           head.paragraphSpacing < spacing,
           let flat = head.mutableCopy() as? NSMutableParagraphStyle {
            flat.paragraphSpacing = spacing
            merged.addAttribute(.paragraphStyle, value: flat,
                                range: NSRange(location: 0, length: merged.length))
        }

        let document = storage.documentRange.location
        let hasNewline = text.character(at: run.location + run.length - 1) == 0x0A
        guard let start = storage.location(document, offsetBy: run.location),
              let split = storage.location(document, offsetBy: run.location + run.length - (hasNewline ? 1 : 0)),
              let end = storage.location(document, offsetBy: run.location + run.length),
              let whole = NSTextRange(location: start, end: end),
              let content = NSTextRange(location: start, end: split),
              let separator = NSTextRange(location: split, end: end) else { return nil }
        let paragraph = MergedParagraph(attributedString: merged)
        paragraph.span(whole, content: content, separator: separator)
        return paragraph
    }

    /// Skip the paragraphs the merged element has already taken. A paragraph
    /// is subsumed exactly when the character before it is a joined newline.
    func textContentManager(_ manager: NSTextContentManager,
                            shouldEnumerate element: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard let storage = manager as? NSTextContentStorage,
              let backing = storage.textStorage,
              let range = element.elementRange else { return true }
        let start = storage.offset(from: storage.documentRange.location, to: range.location)
        guard start > 0, start <= backing.length else { return true }
        return backing.attribute(joinedNewlineAttribute, at: start - 1, effectiveRange: nil) == nil
    }

    /// The whole run of source lines the paragraph at `range` belongs to.
    ///
    /// Walked in **both** directions, because the enumeration does not always
    /// start at the head: asking for the element at a location in the tail —
    /// which is what hit-testing and `textLayoutFragment(for:)` do — arrives
    /// here with a subsumed paragraph's range, and answering with that
    /// paragraph is answering with an element nothing lays out. Every caret in
    /// the tail came back with no rectangle at all until this walked back.
    private func joinedRun(containing range: NSRange, in backing: NSTextStorage,
                           text: NSString) -> NSRange {
        var start = range.location
        while start > 0,
              backing.attribute(joinedNewlineAttribute, at: start - 1, effectiveRange: nil) != nil {
            start = text.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        var end = range.location + range.length
        while end > 0, end <= backing.length,
              backing.attribute(joinedNewlineAttribute, at: end - 1, effectiveRange: nil) != nil {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            let grown = next.location + next.length
            if grown <= end { break }
            end = grown
        }
        return NSRange(location: start, length: end - start)
    }
}

//
//  BlankLineTests.swift
//  MarkdownEditorTests
//
//  Blank lines, as typed. GitHub swallows a run of them — two paragraphs are
//  16pt apart however many Returns were typed between them — and so did the
//  editor, sharing the one gap out over the run, so pressing Return four times
//  moved nothing on screen (build 28). Now one blank line is the gap, exactly
//  as the page has it, and every line past it is a full empty line
//  (`BlockBoxes.extraBlankLines`). Measured from the laid-out text, so what is
//  checked is where the next paragraph lands, not an attribute.
//

import Foundation
import Testing
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit

@MainActor
@Suite struct BlankLineTests {

    /// The laid-out document — no caret, so nothing is revealed, as a reader
    /// sees it.
    private func laidOut(_ text: String) throws -> (EditorDocument, NSTextLayoutManager, NSWindow) {
        let document = EditorDocument(text: text)
        document.styleEverythingNow()
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 2000)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return (document, layoutManager, window)
    }

    /// The top of the line holding `needle`, in the text container.
    private func top(of needle: String, in text: String, _ layoutManager: NSTextLayoutManager) throws -> CGFloat {
        let offset = (text as NSString).range(of: needle).location
        let content = try #require(layoutManager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: offset))
        let fragment = try #require(layoutManager.textLayoutFragment(for: location))
        return fragment.layoutFragmentFrame.minY
    }

    @Test("One blank line is the gap the page has; every line past it is a full line")
    func extraBlankLinesAreLines() throws {
        let one = "Para\n\nNext"
        let (doc1, lm1, w1) = try laidOut(one)
        defer { w1.contentView = nil }
        let four = "Para\n\n\n\n\nNext"
        let (_, lm4, w4) = try laidOut(four)
        defer { w4.contentView = nil }

        let line = doc1.theme.metrics.bodyLineHeight
        let gapOne = try top(of: "Next", in: one, lm1) - top(of: "Para", in: one, lm1)
        let gapFour = try top(of: "Next", in: four, lm4) - top(of: "Para", in: four, lm4)
        #expect(abs(gapFour - gapOne - 3 * line) < 0.5,
                "four blank lines put the next paragraph \(gapFour - gapOne)pt lower than one, not three lines (\(3 * line))")
        // And one is exactly what it was: the paragraph's line and its 16pt gap.
        #expect(abs(gapOne - (line + doc1.theme.metrics.blockGap)) < 0.5)
    }

    /// The same inside a list item, whose blank lines are the item's own and
    /// styled by its own pass: Returns between an item's paragraphs moved
    /// nothing while the same Returns between two paragraphs did.
    @Test("Inside a list item too: one blank line is the margin, the rest are lines")
    func extraBlankLinesInsideAnItemAreLines() throws {
        let one = "- item\n\n  second paragraph"
        let (document, lm1, w1) = try laidOut(one)
        defer { w1.contentView = nil }
        let four = "- item\n\n\n\n\n  second paragraph"
        let (_, lm4, w4) = try laidOut(four)
        defer { w4.contentView = nil }
        let line = document.theme.metrics.bodyLineHeight
        let gapOne = try top(of: "second paragraph", in: one, lm1) - top(of: "- item", in: one, lm1)
        let gapFour = try top(of: "second paragraph", in: four, lm4) - top(of: "- item", in: four, lm4)
        #expect(abs(gapFour - gapOne - 3 * line) < 0.5,
                "four blank lines in an item put its next paragraph \(gapFour - gapOne)pt lower than one, not three lines (\(3 * line))")
    }

    /// …so the caret on the empty line after it stands where the paragraph
    /// typed there will start, and the text does not move as it lands. Checked
    /// for one blank line and for two: the empty last line goes where TextKit
    /// 2 puts it, its own height below the top of the line above.
    @Test("The caret after blank lines at the end stands where the next paragraph lands")
    func theCaretAtTheEndStandsWhereTheNextParagraphLands() throws {
        for blanks in ["\n\n", "\n\n\n"] {
            let ending = "Para" + blanks
            let (textView, window) = try caretAtTheEnd(of: ending)
            defer { window.contentView = nil }
            let screen = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
            let caret = textView.convert(window.convertFromScreen(screen), from: nil).minY - textView.textContainerOrigin.y

            let typed = ending + "Next"
            let (_, lmTyped, wTyped) = try laidOut(typed)
            defer { wTyped.contentView = nil }
            let next = try top(of: "Next", in: typed, lmTyped)
            #expect(abs(caret - next) < 0.5,
                    "after \(blanks.count - 1) blank line(s) the caret stands at \(caret), and what is typed there lands at \(next)")
        }
    }

    private func caretAtTheEnd(of text: String) throws -> (MarkdownTextView, NSWindow) {
        let document = EditorDocument(text: text)
        document.styleEverythingNow()
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 2000)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.invalidateLayout(for: layoutManager.documentRange)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return (textView, window)
    }

    @Test("A blank line before source the page drops still shares its gap")
    func aBlankLineBeforeDroppedSourceIsUnchanged() throws {
        // Ending in a reference definition: the blank line is between two
        // things the page has — the paragraph, and the definition it drops —
        // and holds the share it always held.
        let text = "Para [x].\n\n[x]: https://example.com\n"
        let (_, layoutManager, window) = try laidOut(text)
        defer { window.contentView = nil }
        let content = try #require(layoutManager.textContentManager)
        let blank = try #require(content.location(content.documentRange.location, offsetBy: 10))
        let fragment = try #require(layoutManager.textLayoutFragment(for: blank))
        #expect(fragment.layoutFragmentFrame.height < 1,
                "a blank line before a dropped definition at the end grew to \(fragment.layoutFragmentFrame.height)pt")
    }
}
#endif

//
//  JoinedLineTests.swift
//  MarkdownEditorTests
//
//  The line ending the page does not break at — a newline cmark has already
//  eaten into a token, inside a code span, a link's `(…)`, a raw tag or an
//  HTML comment.
//
//  These drive a **real text view**, and that is not ceremony. The height is
//  the easy half: the corpus sweep can see it, and a merged content element
//  that laid out perfectly and put every caret in the wrong place would score
//  exactly the same. What has to be true is that clicking a character selects
//  that character, that an arrow key steps one character, and that a selection
//  covers the source it appears to cover — all across a join, where the
//  editor's line and the document's line have stopped being the same thing. A
//  wrong caret is worse than a wrong height.
//

import Foundation
import Testing
@testable import MarkdownEditor
@testable import MarkdownCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor @Suite struct JoinedLineTests {

    /// A bound, laid-out editor over `text`, with the caret parked at the very
    /// end — away from anything under test, because arriving reveals.
    @MainActor private final class Editor {
        #if canImport(AppKit)
        let view: MarkdownTextView
        let window: NSWindow
        #else
        let view: MarkdownUITextView
        let window: UIWindow
        #endif
        let document: EditorDocument
        let text: NSString

        init(_ source: String, width: CGFloat = 600) {
            text = source as NSString
            document = EditorDocument(text: source)
            document.styleEverythingNow()
            #if canImport(AppKit)
            // The app's own assembly, hosted in a window — a text view that is
            // not in one lays out with no layout manager at all, and every
            // question here is a question about the view that ships.
            let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
            scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(scrollView)
            window.layoutIfNeeded()
            view = textView
            view.setSelectedRange(NSRange(location: text.length, length: 0))
            view.layoutSubtreeIfNeeded()
            #else
            view = MarkdownUITextView.make(document: document)
            view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            window = UIWindow(frame: view.frame)
            window.addSubview(view)
            window.makeKeyAndVisible()
            view.selectedRange = NSRange(location: text.length, length: 0)
            // UIKit does not route a programmatic selection through the
            // document the way `NSTextView.setSelectedRanges` does, so the two
            // platforms would otherwise start in different reveal states —
            // which is a difference in the *test*, not in the editor.
            document.selectionDidChange(NSRange(location: text.length, length: 0))
            view.layoutIfNeeded()
            #endif
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }

        var layoutManager: NSTextLayoutManager { view.textLayoutManager! }

        var caret: NSRange {
            #if canImport(AppKit)
            view.selectedRange()
            #else
            view.selectedRange
            #endif
        }

        func place(caret offset: Int, length: Int = 0) {
            #if canImport(AppKit)
            view.setSelectedRange(NSRange(location: offset, length: length))
            #else
            view.selectedRange = NSRange(location: offset, length: length)
            document.selectionDidChange(NSRange(location: offset, length: length))
            #endif
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }

        /// Every visual line in the document, top-to-bottom.
        var visualLines: [String] {
            var out: [String] = []
            layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                       options: [.ensuresLayout]) { fragment in
                guard let paragraph = fragment.textElement as? NSTextParagraph else { return true }
                let whole = paragraph.attributedString.string
                for line in fragment.textLineFragments {
                    let r = line.characterRange
                    guard let range = Range(r, in: whole) else { continue }
                    out.append(String(whole[range]).replacingOccurrences(of: "\n", with: ""))
                }
                return true
            }
            return out
        }

        var height: CGFloat { layoutManager.usageBoundsForTextContainer.height }

        /// Is the newline before `offset` marked as one the page keeps?
        func joins(before offset: Int) -> Bool {
            document.storage.attribute(joinedNewlineAttribute, at: offset - 1,
                                       effectiveRange: nil) != nil
        }

        /// The x of the insertion point for `offset`, in the text view's own
        /// coordinates — what a click at that spot would be measured against.
        func caretPoint(_ offset: Int) -> CGPoint? {
            guard let location = layoutManager.textContentManager?
                .location(layoutManager.documentRange.location, offsetBy: offset),
                  let range = NSTextRange(location: location, end: location) else { return nil }
            var found: CGRect?
            layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
                found = rect
                return false
            }
            guard let rect = found else { return nil }
            #if canImport(AppKit)
            let origin = view.textContainerOrigin
            return CGPoint(x: rect.minX + origin.x, y: rect.midY + origin.y)
            #else
            return CGPoint(x: rect.minX + view.textContainerInset.left,
                           y: rect.midY + view.textContainerInset.top)
            #endif
        }

        /// Which source offset the view puts the caret at for a click at
        /// `point` — the real hit-test, not a re-derivation of one.
        func offsetOfClick(at point: CGPoint) -> Int {
            #if canImport(AppKit)
            return view.characterIndexForInsertion(at: point)
            #else
            guard let position = view.closestPosition(to: point) else { return -1 }
            return view.offset(from: view.beginningOfDocument, to: position)
            #endif
        }
    }

    /// The whole family in one note: a code span, a link and a raw tag, each
    /// written across a line ending.
    private let codeSpan = "Above.\n\n`foo   bar \nbaz`\n\nBelow.\n"

    // MARK: - What the page sees

    /// The backticks are still in these strings, and should be: concealment is
    /// a font transform, so a hidden marker is a character of width ~0 and not
    /// a character that is gone. What the join changes is how many *lines*
    /// there are.
    @Test func aCodeSpanWrittenAcrossALineEndingIsOneLine() {
        let editor = Editor(codeSpan)
        #expect(editor.visualLines == ["Above.", "", "`foo   bar  baz`", "", "Below.", ""])
    }

    /// The control, and the reason this is not "join every newline in a
    /// paragraph": Preview renders with hard breaks on, so an ordinary line
    /// ending between two words really is a `<br>` and really is two lines.
    @Test func anOrdinaryLineEndingIsStillALineEnding() {
        let editor = Editor("Above.\n\nfoo   bar \nbaz\n\nBelow.\n")
        #expect(editor.visualLines == ["Above.", "", "foo   bar ", "baz", "", "Below.", ""])
    }

    /// Every note here ends with a block the construct is not in, because the
    /// caret is parked at the end of the document and the end of the document
    /// is *inside* the last block — which reveals it.

    @Test func aLinkAndARawTagJoinAndAnUnquotedDestinationDoesNot() {
        // A link whose `(…)` wraps needs no join when nothing follows it: the
        // whole of the second line is inside the concealed `](…)` marker, so
        // `collapseConcealedLines` has already taken it down to a hairline. The
        // join is what carries the case where the line has something left on
        // it — the source of two different-looking mechanisms for one page
        // line, and the reason this asserts both.
        #expect(Editor("[link](   /uri\n  \"title\"  )\n\nEnd.\n").visualLines.first
                == "[link](   /uri")
        #expect(Editor("[link](/uri\n\"t\") tail\n\nEnd.\n").visualLines.first
                == "[link](/uri \"t\") tail")
        #expect(Editor("a <b data=\"x\ny\"> c\n\nEnd.\n").visualLines.first == "a <b data=\"x y\"> c")
        // `[link](foo⏎bar)` is *not* a link — an unquoted destination may not
        // contain a line ending — so cmark prints both lines and so does this.
        #expect(Editor("[link](foo\nbar)\n\nEnd.\n").visualLines.prefix(2)
                == ["[link](foo", "bar)"])
    }

    /// `` ``⏎foo⏎bar⏎`` `` — the fence lines draw nothing and were already
    /// collapsed to a hairline, so they are not lines of the page and there is
    /// nothing to join them to. Joining them anyway would head the merged
    /// element with a 0.01pt line and pin the whole construct to it.
    @Test func aLineEndingBesideAConcealedLineIsNotJoined() {
        let source = "``\nfoo\nbar\n``\n\nEnd.\n"
        let editor = Editor(source)
        #expect(editor.visualLines == ["``", "foo bar", "``", "", "End.", ""])
        let ns = source as NSString
        #expect(editor.joins(before: ns.range(of: "bar").location))
        #expect(!editor.joins(before: ns.range(of: "foo").location))
    }

    /// A note that does not end with a newline, with the join in its last
    /// block: the merged element's paragraph *separator* is then empty, which
    /// is a shape only the end of the document produces.
    @Test func aJoinAtTheEndOfANoteWithNoTrailingNewlineLaysOut() {
        let editor = Editor("Above.\n\n`foo\nbar`")
        editor.place(caret: 0)
        #expect(editor.visualLines == ["Above.", "", "`foo bar`"])
        // And revealed, where the separator is empty and the run is the last
        // thing in the document.
        editor.place(caret: (editor.text.length) - 1)
        #expect(editor.visualLines == ["Above.", "", "`foo", "bar`"])
        #expect(editor.height > 0)
    }

    // MARK: - Editing across the join

    @Test func clickingAnywhereInTheJoinedTailLandsOnItsSourceOffset() throws {
        let editor = Editor(codeSpan)
        let tail = editor.text.range(of: "baz`")
        for offset in tail.location..<(tail.location + tail.length) {
            let here = try #require(editor.caretPoint(offset))
            let next = try #require(editor.caretPoint(offset + 1))
            // A third of the way into the glyph: unambiguously this character
            // and not the boundary with the next one.
            let point = CGPoint(x: here.x + (next.x - here.x) / 3, y: here.y)
            #expect(editor.offsetOfClick(at: point) == offset,
                    "a click on the character at \(offset) chose \(editor.offsetOfClick(at: point))")
        }
    }

    /// The joined tail is on the same visual line as the head, so its caret
    /// rectangles are too — the property a merged element that only widened
    /// `elementRange` failed, silently, with every height still perfect.
    @Test func theJoinedTailHasCaretRectanglesOnTheJoinedLine() throws {
        let editor = Editor(codeSpan)
        let head = try #require(editor.caretPoint(editor.text.range(of: "foo").location))
        for word in ["baz", "`\n\nBelow"] {
            let offset = editor.text.range(of: word).location
            let point = try #require(editor.caretPoint(offset), "no caret rect at \(offset)")
            if word == "baz" {
                #expect(point.y == head.y)
                #expect(point.x > head.x)
            }
        }
    }

    #if canImport(AppKit)
    /// Down-arrow lands *in* the construct, which reveals it — and from then
    /// on the arrows walk the source lines, because that is what is on screen.
    /// The join is a caret-away presentation, exactly like every marker this
    /// editor conceals; a down-arrow that skipped the second source line
    /// entirely would be a line the writer could not reach with the keyboard.
    @Test func arrowingDownArrivesInTheConstructAndThenWalksItsSourceLines() {
        let editor = Editor(codeSpan)
        let tail = editor.text.range(of: "baz`").location
        editor.place(caret: editor.text.range(of: "Above.").location + 1)
        editor.view.moveDown(nil)                              // the blank line
        editor.view.moveDown(nil)                              // into the construct
        let landed = editor.caret.location
        #expect(landed < tail, "the first line of the construct, not its tail")
        #expect(!editor.joins(before: tail), "arriving did not reveal the source")

        editor.view.moveDown(nil)
        #expect(editor.caret.location >= tail, "the revealed second source line")
        editor.view.moveUp(nil)
        #expect(editor.caret.location == landed)

        // And leaving closes it back up.
        editor.place(caret: editor.text.length)
        #expect(editor.joins(before: tail))
    }

    @Test func steppingRightWalksEveryCharacterOfTheJoin() {
        let editor = Editor(codeSpan)
        let start = editor.text.range(of: "bar").location
        editor.place(caret: start)
        var walk = [start]
        for _ in 0..<8 {
            editor.view.moveForward(nil)
            walk.append(editor.caret.location)
        }
        #expect(walk == Array(start...(start + 8)),
                "the caret skipped a character of the source: \(walk)")
    }

    @Test func shiftSelectingAcrossTheJoinSelectsTheSourceRange() {
        let editor = Editor(codeSpan)
        let start = editor.text.range(of: "bar").location
        editor.place(caret: start)
        for _ in 0..<8 { editor.view.moveForwardAndModifySelection(nil) }
        // Eight characters of *source*, line ending included — the selection is
        // over the document, not over the line the editor drew.
        #expect(editor.caret == NSRange(location: start, length: 8))
        #expect(editor.text.substring(with: editor.caret) == "bar \nbaz")
    }

    @Test func typingInsideTheJoinEditsTheRightCharactersAndTheJoinReForms() {
        let editor = Editor(codeSpan)
        let target = editor.text.range(of: "baz").location + 1
        editor.place(caret: target)
        editor.view.insertText("X", replacementRange: editor.caret)
        #expect(editor.document.text.contains("bXaz`"))
        #expect(!editor.document.text.contains("bXaz`\n\nbaz"))
        // Away again, and the construct closes back up over the edit.
        editor.place(caret: (editor.document.text as NSString).length)
        editor.document.styleEverythingNow()
        editor.layoutManager.ensureLayout(for: editor.layoutManager.documentRange)
        #expect(editor.visualLines.contains("`foo   bar  bXaz`"))
    }
    /// An edit that destroys the construct takes the join with it — the mark
    /// lives on the newline and `applyBase` clears the block's attributes
    /// before anything re-decides, so there is no state to go stale.
    @Test func deletingTheClosingDelimiterTakesTheJoinApart() {
        let editor = Editor(codeSpan)
        let closing = editor.text.range(of: "baz`").location + 3
        editor.place(caret: closing, length: 1)
        editor.view.insertText("", replacementRange: editor.caret)
        editor.place(caret: (editor.document.text as NSString).length)
        editor.layoutManager.ensureLayout(for: editor.layoutManager.documentRange)
        #expect(editor.visualLines == ["Above.", "", "`foo   bar ", "baz", "", "Below.", ""])
    }
    #endif

    // MARK: - The caret reveals, like every other concealment here

    @Test func theCaretArrivingInTheConstructBringsTheSourceLinesBack() {
        let editor = Editor(codeSpan)
        let inside = editor.text.range(of: "bar").location
        #expect(editor.joins(before: editor.text.range(of: "baz").location))

        editor.place(caret: inside)
        #expect(!editor.joins(before: editor.text.range(of: "baz").location))
        #expect(editor.visualLines == ["Above.", "", "`foo   bar ", "baz`", "", "Below.", ""])

        editor.place(caret: editor.text.length)
        #expect(editor.joins(before: editor.text.range(of: "baz").location))
        #expect(editor.visualLines == ["Above.", "", "`foo   bar  baz`", "", "Below.", ""])
    }
}

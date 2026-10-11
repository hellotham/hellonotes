//
//  HeadingTypingTests.swift
//  MarkdownEditorTests
//
//  Typing in a heading restyles the heading, and nothing on screen moves.
//
//  It restyled the whole note. 120ms after a keystroke the overlay refresh
//  re-reads the note with cmark, and it repainted every block whenever cmark
//  disagreed with the cache it had shifted across the edit — which it always
//  does when the edit touched a run, and a heading's text is one. Every block
//  restyled is a layout invalidated, so TextKit 2 threw away the whole note's
//  layout and re-estimated every height above the screen: measured here, the
//  scroll offset moved 1,470pt and the paragraph under the heading 200pt on
//  screen, with frames where it had no position at all — "several layout
//  shifts per keystroke, and the screen often goes blank" (build 28).
//
//  Async on purpose: the refresh is a main-actor task, and a synchronous test
//  pumping the run loop never lets it run — the probe that first looked at
//  this saw nothing wrong for exactly that reason.
//

import Foundation
import Testing
@testable import MarkdownEditor
#if canImport(AppKit)
import AppKit

@MainActor
@Suite struct HeadingTypingTests {

    /// Long enough that the heading is screens down, where TextKit 2 knows the
    /// heights above it only as estimates once its layout is thrown away.
    static func note(heading: String) -> String {
        var parts = ["# Title", ""]
        for i in 1...300 { parts += ["Paragraph \(i) before, long enough to be a line of prose in a note.", ""] }
        parts += [heading, "", "The paragraph under the heading.", ""]
        for i in 1...300 { parts += ["Paragraph \(i) after, long enough to be a line of prose in a note.", ""] }
        return parts.joined(separator: "\n")
    }

    private func turn() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }

    /// The run loop and the main actor's tasks, both, for `seconds`.
    private func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            turn()
            try? await Task.sleep(for: .milliseconds(1))
        } while Date() < deadline
    }

    @Test(arguments: ["## A heading in the middle", "# A first-level heading"])
    func typingInAHeadingRestylesTheHeadingAndMovesNothing(_ heading: String) async throws {
        let document = EditorDocument(text: Self.note(heading: heading))
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        var restyled: [NSRange] = []
        let invalidate = document.onRestyle
        document.onRestyle = { range in restyled.append(range); invalidate?(range) }
        scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        // Ordered in, far off any screen: laid out and drawn as a window is.
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        await pump(1.0)   // the background styling pass finishes

        window.makeFirstResponder(textView)
        let end = NSMaxRange((textView.string as NSString).range(of: heading))
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        await pump(0.5)

        let layoutManager = try #require(textView.textLayoutManager)
        let content = try #require(layoutManager.textContentManager)
        /// Where the paragraph under the heading is on screen.
        func below() -> CGFloat? {
            let offset = (textView.string as NSString).range(of: "The paragraph under the heading").location
            guard let location = content.location(content.documentRange.location, offsetBy: offset),
                  let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
            return fragment.layoutFragmentFrame.minY - scrollView.contentView.bounds.origin.y
        }
        let scroll = scrollView.contentView.bounds.origin.y
        let place = try #require(below())

        for key in "words" {
            restyled.removeAll()
            textView.insertText(String(key), replacementRange: NSRange(location: NSNotFound, length: 0))
            await pump(0.4)   // past the overlay refresh
            let span = restyled.reduce(0) { $0 + $1.length }
            #expect(span < 2_000, "typing ‘\(key)’ in a heading restyled \(span) characters of a note of \(textView.string.count)")
            #expect(abs(scrollView.contentView.bounds.origin.y - scroll) < 0.5,
                    "typing ‘\(key)’ scrolled the note from \(scroll) to \(scrollView.contentView.bounds.origin.y)")
            let now = try #require(below(), "the paragraph under the heading has no place on screen")
            #expect(abs(now - place) < 0.5, "typing ‘\(key)’ moved the paragraph under the heading from \(place) to \(now)")
        }
    }
}
#endif

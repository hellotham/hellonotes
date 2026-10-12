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

    /// The run loop and the main actor's tasks, both, for `seconds` — in
    /// looks, and with the run loop last.
    ///
    /// **Looks, not a deadline.** Every test of this suite shares the main
    /// actor, so one sleep here can come back with other tests' work done
    /// and the clock already past — and a wait that ends there ends on
    /// whatever ran in that sleep, with no turn of the run loop after it.
    ///
    /// **The run loop last**, because that is the order on screen. The
    /// overlay refresh is a main-actor task, so it runs in the sleep; it
    /// restyles the heading with the blank lines round it, and TextKit then
    /// makes the paragraph after them a new fragment — one with no frame
    /// until the view's next layout pass, which is the run loop's and comes
    /// before anything is drawn. Read between the two, the paragraph was
    /// "moved" by exactly the scroll offset: to a frame of zero
    /// (implemented.md §51.49).
    private func pump(_ seconds: TimeInterval) async {
        for _ in 0..<max(1, Int((seconds / 0.003).rounded(.up))) {
            turn()
            try? await Task.sleep(for: .milliseconds(1))
        }
        turn()
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
        /// Where the paragraph under the heading is on screen — `nil` while it
        /// has no place there: a fragment made and not yet laid out reports a
        /// frame of zero, which is where nothing is drawn.
        func below() -> CGFloat? {
            let offset = (textView.string as NSString).range(of: "The paragraph under the heading").location
            guard let location = content.location(content.documentRange.location, offsetBy: offset),
                  let fragment = layoutManager.textLayoutFragment(for: location),
                  fragment.state == .layoutAvailable else { return nil }
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
            // With the run loop turned and still no place, the screen has a
            // gap where the paragraph was — what build 28 drew, and what
            // restyling the whole note on the refresh does here.
            let now = try #require(below(), "typing ‘\(key)’ left the paragraph under the heading with no place on screen")
            // Said in full when it fails: this message is what showed the
            // runner's failure to be a fragment not yet laid out — the
            // paragraph "moved" by the scroll offset to the point, and back
            // where it was once the viewport was laid out (implemented.md
            // §51.49). Asked only on a failure, so a run that passes is the
            // run it was.
            var seen = ""
            if abs(now - place) >= 0.5 {
                let controller = layoutManager.textViewportLayoutController
                let offset = (textView.string as NSString).range(of: "The paragraph under the heading").location
                let location = content.location(content.documentRange.location, offsetBy: offset)
                let inViewport = location.flatMap { controller.viewportRange?.contains($0) } ?? false
                let usage = layoutManager.usageBoundsForTextContainer
                controller.layoutViewport()
                let laidOut = below()
                seen = " — in the viewport's range: \(inViewport); the viewport: \(controller.viewportBounds); "
                    + "the text's height as TextKit has it: \(usage.height); the text view's: \(textView.frame.height); "
                    + "and after the viewport is laid out again: \(laidOut.map { "\($0)" } ?? "nowhere")"
            }
            #expect(abs(now - place) < 0.5,
                    "typing ‘\(key)’ moved the paragraph under the heading from \(place) to \(now)\(seen)")
        }
    }
}
#endif

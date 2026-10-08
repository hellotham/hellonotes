//
//  ScrollPastEndTests.swift
//  MarkdownEditorTests
//
//  Room to scroll past the end of a note is room to scroll *into*, never a band
//  of the view counted as covered.
//
//  The space was a bottom content inset of half the viewport, and a scroll view
//  keeps what it scrolls to inside its bounds *less* its insets. So the editor
//  believed the lower half of itself was hidden: a tap on a line down there
//  scrolled that line up to the middle. And on iPad the software keyboard's
//  inset came on top — 313pt of ours and 407pt of the keyboard's against a
//  626pt view — leaving a band of negative height, so UIKit's own
//  scroll-to-the-caret put the tapped line 94pt above the top edge. Measured
//  with a probe; the numbers are in docs/implemented.md.
//
//  The last test holds the other side: a fix that simply removed the space
//  would pass the rest.
//

import Foundation
import Testing
@testable import MarkdownEditor

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite struct ScrollPastEndTests {

    /// Sixty one-line paragraphs: several screens, so the note scrolls and the
    /// space past its end applies.
    static let note = (0..<60).map { "Paragraph \($0), one line of a long note." }.joined(separator: "\n\n")
    static let size = CGSize(width: 600, height: 626)

    #if !canImport(AppKit)

    /// A live editor filling a view controller's view, laid out whole so every
    /// position is real rather than estimated. `keyboard` is the bottom safe
    /// area a software keyboard gives the view — the way SwiftUI's keyboard
    /// avoidance hands it over.
    private func editor(keyboard: CGFloat = 0) throws -> (MarkdownUITextView, UIWindow) {
        let document = EditorDocument(text: Self.note)
        document.styleEverythingNow()
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        let textView = MarkdownUITextView.make(document: document)
        textView.frame = controller.view.bounds
        controller.view.addSubview(textView)
        controller.additionalSafeAreaInsets.bottom = keyboard
        controller.view.layoutIfNeeded()
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        textView.layoutIfNeeded()
        return (textView, window)
    }

    /// The caret rect at the start of `needle` — what UIKit scrolls to.
    private func caret(at needle: String, in textView: MarkdownUITextView) throws -> CGRect {
        let offset = (Self.note as NSString).range(of: needle).location
        let position = try #require(textView.position(from: textView.beginningOfDocument, offset: offset))
        return textView.caretRect(for: position)
    }

    /// Scroll so `rect` sits `fraction` of the way down the view.
    private func place(_ rect: CGRect, at fraction: CGFloat, in textView: MarkdownUITextView) {
        textView.setContentOffset(CGPoint(x: 0, y: rect.midY - fraction * textView.bounds.height), animated: false)
        textView.layoutIfNeeded()
    }

    @Test func aLineOnScreenInTheLowerHalfIsNotScrolledTo() throws {
        let (textView, window) = try editor()
        defer { window.isHidden = true }
        let line = try caret(at: "Paragraph 30", in: textView)
        place(line, at: 0.75, in: textView)
        let before = textView.contentOffset
        #expect(line.minY > before.y + textView.bounds.height / 2 && line.maxY < before.y + textView.bounds.height,
                "the line is not in the lower half of the view — this test is not looking at the case")

        textView.scrollRectToVisible(line, animated: false)
        #expect(textView.contentOffset == before,
                "a line already on screen was scrolled from \(before.y) to \(textView.contentOffset.y)")
    }

    @Test func withTheKeyboardUpACoveredLineComesToRestAboveIt() throws {
        let keyboard: CGFloat = 407
        let (textView, window) = try editor(keyboard: keyboard)
        defer { window.isHidden = true }
        #expect(textView.adjustedContentInset.bottom >= keyboard,
                "the keyboard's inset never reached the view — this test is not looking at the case")
        let line = try caret(at: "Paragraph 30", in: textView)
        place(line, at: 0.75, in: textView)   // under the keyboard

        textView.scrollRectToVisible(line, animated: false)
        let top = textView.contentOffset.y + textView.adjustedContentInset.top
        let bottom = textView.contentOffset.y + textView.bounds.height - textView.adjustedContentInset.bottom
        #expect(line.minY >= top - 0.5 && line.maxY <= bottom + 0.5,
                "the line ended at \(line.minY)…\(line.maxY), outside the \(top)…\(bottom) the keyboard leaves")
    }

    @Test func theLastLineCanStillBeScrolledToTheMiddle() throws {
        let (textView, window) = try editor()
        defer { window.isHidden = true }
        // Measured at the end of the note, where TextKit has laid it out: until
        // the viewport gets there UIKit reports an estimate — 1,305pt here, for
        // a note whose last line sits at 2,384.
        place(try caret(at: "Paragraph 59", in: textView), at: 0.5, in: textView)
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        let last = try caret(at: "Paragraph 59", in: textView)
        let furthest = textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height
        #expect(furthest >= last.midY - textView.bounds.height / 2 - 1,
                "the note can no longer scroll its last line up to the middle: it stops at \(furthest)")
    }

    #else

    /// A live editor in a window, laid out whole.
    private func editor() throws -> (MarkdownTextView, NSScrollView, NSWindow) {
        let document = EditorDocument(text: Self.note)
        document.styleEverythingNow()
        let (scrollView, textView) = MarkdownTextView.scrollableEditor(document: document)
        scrollView.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(scrollView)
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        window.contentView?.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        return (textView, scrollView, window)
    }

    /// The rect of the line starting `needle`, in the text view's coordinates.
    private func line(at needle: String, in textView: MarkdownTextView) throws -> (NSRange, CGRect) {
        let offset = (Self.note as NSString).range(of: needle).location
        let layoutManager = try #require(textView.textLayoutManager)
        let content = try #require(layoutManager.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: offset))
        let fragment = try #require(layoutManager.textLayoutFragment(for: location))
        let origin = textView.textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        return (NSRange(location: offset, length: 0),
                CGRect(x: origin.x + frame.minX, y: origin.y + frame.minY, width: frame.width, height: frame.height))
    }

    @Test func aLineOnScreenInTheLowerHalfIsNotScrolledTo() throws {
        let (textView, scrollView, window) = try editor()
        defer { window.contentView = nil }
        let (range, rect) = try line(at: "Paragraph 30", in: textView)
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: rect.midY - 0.75 * clip.bounds.height))
        scrollView.reflectScrolledClipView(clip)
        let before = clip.bounds.origin
        #expect(rect.minY > before.y + clip.bounds.height / 2 && rect.maxY < before.y + clip.bounds.height,
                "the line is not in the lower half of the view — this test is not looking at the case")

        textView.scrollRangeToVisible(range)
        #expect(clip.bounds.origin == before,
                "a line already on screen was scrolled from \(before.y) to \(clip.bounds.origin.y)")
    }

    @Test func theLastLineCanStillBeScrolledToTheMiddle() throws {
        let (textView, scrollView, window) = try editor()
        defer { window.contentView = nil }
        let (_, last) = try line(at: "Paragraph 59", in: textView)
        let clip = scrollView.contentView
        let furthest = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: 1e9), size: clip.bounds.size)).origin.y
        #expect(furthest >= last.midY - clip.bounds.height / 2 - 1,
                "the note can no longer scroll its last line up to the middle: it stops at \(furthest)")
    }

    #endif
}

//
//  UITextViewBindTests.swift
//  MarkdownEditorTests
//
//  `bind(to:)` hands the text view its document by *replacing* the text storage
//  on the content manager. AppKit supports that; these tests ask whether UIKit
//  does — i.e. whether a `UITextView` that had its storage swapped still agrees
//  with that storage about how long the document is.
//
//  It matters because every disagreement is an out-of-bounds waiting to happen:
//  UIKit reads text ranges from its own cached notion of the document, and the
//  first thing that walks the storage over one of those ranges throws
//  NSRangeException from a stack with no app frames in it.
//

#if canImport(UIKit) && !canImport(AppKit)
import UIKit
import Testing
@testable import MarkdownEditor

@MainActor
@Suite struct UITextViewBindTests {

    /// A note big enough that a stale "empty document" is unmistakable.
    private func sampleText() -> String {
        (0..<200).map { i in
            "## Section \(i)\n\nParagraph \(i) with **bold**, `code` and a [[Link \(i)]].\n\n> quoted \(i)\n\n- bullet \(i)\n"
        }.joined()
    }

    private func hosted(_ document: EditorDocument) -> (MarkdownUITextView, UIWindow) {
        let tv = MarkdownUITextView.make(document: document)
        tv.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        let window = UIWindow(frame: tv.frame)
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()
        return (tv, window)
    }

    @Test func theTextViewAgreesWithItsDocumentAboutTheDocument() {
        let text = sampleText()
        let document = EditorDocument(text: text)
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let length = document.storage.length

        #expect(length == (text as NSString).length)
        #expect(tv.textStorage.length == length)
        #expect((tv.text as NSString?)?.length == length)
        #expect(tv.offset(from: tv.beginningOfDocument, to: tv.endOfDocument) == length)
    }

    /// The reported crash: scroll, then tap. A tap is a selection change plus a
    /// request for the caret's geometry, and scrolling asks UIKit to lay out a
    /// range it has not seen. Both go through UIKit's own view of the document.
    @Test func scrollingThenSelectingLateInTheDocumentDoesNotThrow() {
        let document = EditorDocument(text: sampleText())
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let length = document.storage.length

        tv.setContentOffset(CGPoint(x: 0, y: max(0, tv.contentSize.height - 900)), animated: false)
        tv.layoutIfNeeded()
        tv.ensureVisibleRangeStyled()

        let caret = NSRange(location: max(0, length - 20), length: 0)
        tv.selectedRange = caret
        tv.scrollRangeToVisible(caret)
        tv.layoutIfNeeded()

        #expect(tv.selectedRange.location == caret.location)
        // What a tap actually asks for.
        if let position = tv.position(from: tv.beginningOfDocument, offset: caret.location) {
            _ = tv.caretRect(for: position)
        }
        _ = tv.selectionRects(for: tv.textRange(from: tv.beginningOfDocument, to: tv.endOfDocument)!)
    }

    /// Find was switched off on the theory that it walked stale ranges. It was
    /// walking an empty `textStorage`; the invariant above is what makes it
    /// safe, so this only checks the feature is actually on and that the text
    /// it would search is the note's.
    @Test func findIsEnabledAndSearchesTheNoteOnScreen() {
        let document = EditorDocument(text: sampleText())
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        #expect(tv.isFindInteractionEnabled)
        #expect(tv.findInteraction != nil)
        #expect(tv.text.contains("Section 137"))
    }


    // MARK: - The keyboard bar

    /// A `ToolbarItemGroup(placement: .keyboard)` was tried first and never
    /// appeared — SwiftUI attaches those to responders it owns, and this one is
    /// a `UITextView` inside a representable. Nothing crashed; the formatting
    /// was simply unreachable, which is the failure this test exists to catch.
    @Test func theKeyboardBarIsAttachedWithTheFormattingCommands() {
        let (tv, _) = hosted(EditorDocument(text: "plain line\n"))
        let bar = try? #require(tv.inputAccessoryView)
        let labels = Set(bar.map(allAccessibilityLabels) ?? [])
        for command in ["Bold", "Italic", "Strikethrough", "Highlight", "Code",
                        "Blockquote", "Bulleted List", "Numbered List",
                        "Heading 1", "Heading 2", "Heading 3",
                        "Undo", "Redo", "Hide Keyboard"] {
            #expect(labels.contains(command), "the keyboard bar is missing \(command)")
        }
    }

    /// Every accessibility label in a view tree. The bar is a scrolling stack
    /// of buttons rather than a `UIToolbar`, so its commands are descendants,
    /// not `items`.
    private func allAccessibilityLabels(_ view: UIView) -> [String] {
        (view.accessibilityLabel.map { [$0] } ?? [])
            + view.subviews.flatMap(allAccessibilityLabels)
    }

    /// The other half: the commands the bar sends have to reach the document.
    /// iOS routes them through `UITextInput.replace(_:withText:)` — the path a
    /// keystroke takes — and that had never been run.
    @Test func formattingFromTheBarEditsTheDocument() {
        let document = EditorDocument(text: "plain line\n")
        let (tv, _) = hosted(document)

        tv.selectedRange = NSRange(location: 0, length: 5)
        tv.apply(.bold)
        #expect(document.text.hasPrefix("**plain**"))

        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.apply(.blockquote)
        #expect(document.text.hasPrefix("> **plain**"))
    }


    /// Tapping into a note has to start editing: become first responder, show a
    /// caret, and bring up the keyboard (which is what carries the format bar).
    @Test func tappingIntoTheNoteStartsEditing() {
        let (tv, _) = hosted(EditorDocument(text: "plain line\n"))
        #expect(tv.isEditable)
        #expect(tv.canBecomeFirstResponder)
        #expect(tv.becomeFirstResponder())
        #expect(tv.isFirstResponder)
        #expect(tv.inputAccessoryView?.frame.height == 44)
        // A zero-width accessory view is laid out by the keyboard, not by us,
        // and an empty one can take the keyboard presentation down with it.
        #expect((tv.inputAccessoryView?.frame.width ?? 0) > 0)

        // The caret itself: UIKit's selection machinery has to be installed on
        // a text view built around a container we made, or there is a document
        // on screen and no way to type into it.
        let range = tv.selectedTextRange
        #expect(range != nil)
        if let start = range?.start {
            let caret = tv.caretRect(for: start)
            #expect(caret.height > 0)
            #expect(caret.origin.x.isFinite && caret.origin.y.isFinite)
        }
    }


    /// The link tap must never compete with the text view's own caret tap.
    /// Without a delegate permitting simultaneous recognition, ours wins, does
    /// nothing (most taps are not on a link), and the tap is eaten — a note you
    /// can scroll and cannot type into.
    @Test func theLinkTapDoesNotStealTheCaretTap() {
        let (tv, _) = hosted(EditorDocument(text: "plain [[Link]] line\n"))
        let tap = tv.linkTapRecognizer
        #expect(tap != nil)
        // Its delegate must not be the text view: UIKit already uses the view
        // as the delegate of its own recognisers, so answering for all of them
        // would replace UIKit's arbitration rather than add to ours.
        #expect(tap?.delegate != nil)
        #expect(tap?.delegate !== tv)

        guard let tap, let delegate = tap.delegate else { return }
        let others = (tv.gestureRecognizers ?? []).filter { $0 !== tap }
        #expect(!others.isEmpty)
        for other in others {
            #expect(delegate.gestureRecognizer?(tap, shouldRecognizeSimultaneouslyWith: other) == true)
        }
    }

}
#endif

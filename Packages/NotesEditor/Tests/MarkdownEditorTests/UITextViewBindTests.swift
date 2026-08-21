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

    // MARK: - Autocomplete

    /// The caret inside a half-typed `[[link` has to reach the host, or the
    /// completion list has nothing to draw. The document has answered this
    /// since it was written; on iOS nothing ever asked it.
    @Test func aHalfTypedWikiLinkIsReportedToTheHost() {
        let document = EditorDocument(text: "before\n\nsee [[Sec\n\nafter\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        var reported: EditorDocument.InlineContext?
        var rect = CGRect.zero
        tv.onInlineContextChange = { context, caret in reported = context; rect = caret }

        let caret = (document.text as NSString).range(of: "[[Sec").upperBound
        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.reportInlineContext()

        #expect(reported?.kind == .wikiLink)
        #expect(reported?.query == "Sec")
        // The rect positions a popup; a zero one puts it in the corner.
        #expect(rect.height > 0)
        #expect(rect.origin.x.isFinite && rect.origin.y.isFinite)
    }

    /// Plain text must clear the popup, not leave the last one on screen.
    @Test func plainTextReportsNoContext() {
        let document = EditorDocument(text: "just a line of prose\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        var calls = 0
        var reported: EditorDocument.InlineContext? = .init(kind: .tag, range: NSRange(location: 0, length: 1), query: "x")
        tv.onInlineContextChange = { context, _ in calls += 1; reported = context }

        tv.selectedRange = NSRange(location: 5, length: 0)
        tv.reportInlineContext()

        #expect(calls == 1)
        #expect(reported == nil)
    }

    /// Accepting a completion replaces the whole construct — markers included —
    /// through the proxy the host holds.
    @Test func acceptingACompletionThroughTheProxyRewritesTheLink() {
        let document = EditorDocument(text: "see [[Sec\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        var reported: EditorDocument.InlineContext?
        tv.onInlineContextChange = { context, _ in reported = context }
        tv.selectedRange = NSRange(location: 9, length: 0)
        tv.reportInlineContext()

        let proxy = EditorProxy()
        proxy.textView = tv
        #expect(proxy.replace(range: reported!.range, with: "[[Section One]]"))
        #expect(document.text == "see [[Section One]]\n")
        // Through the UITextInput path, so the document saw the edit too.
        #expect(tv.textStorage.length == (document.text as NSString).length)
    }

    /// The outline's jump-to-heading drives this. It must land on the heading
    /// rather than somewhere plausible near it.
    @Test func theProxyScrollsAndMovesTheCaret() {
        let document = EditorDocument(text: sampleText())
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        let target = (document.text as NSString).range(of: "## Section 180")
        #expect(target.location != NSNotFound)

        let proxy = EditorProxy()
        proxy.textView = tv
        proxy.setSelection(NSRange(location: target.location, length: 0))
        proxy.scroll(to: target)
        tv.layoutIfNeeded()

        #expect(tv.selectedRange.location == target.location)
        #expect(tv.contentOffset.y > 0)
    }

    // MARK: - Ghost text

    /// The invariant the whole feature rests on: a suggestion that is showing
    /// is *not* in the document.
    @Test func aShowingSuggestionIsNotInTheDocument() {
        let document = EditorDocument(text: "The quick brown fox\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let caret = (document.text as NSString).range(of: "fox").upperBound

        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: caret, text: " jumps over the lazy dog"))

        #expect(tv.inlineSuggestion != nil)
        #expect(document.text == "The quick brown fox\n")
        #expect(tv.textStorage.length == (document.text as NSString).length)
    }

    /// Offered only where it can be drawn honestly — never mid-line, and never
    /// on top of the `[[link]]` completion, which wants the same tap.
    @Test func aSuggestionIsRefusedWhereItCannotBeDrawnHonestly() {
        let document = EditorDocument(text: "one two three\n\nsee [[Sec\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let ns = document.text as NSString

        // Mid-line.
        let midLine = ns.range(of: "two").location
        tv.selectedRange = NSRange(location: midLine, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: midLine, text: "nope"))
        #expect(tv.inlineSuggestion == nil)

        // Inside a half-typed wiki link.
        let inLink = ns.range(of: "[[Sec").upperBound
        tv.selectedRange = NSRange(location: inLink, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: inLink, text: "nope"))
        #expect(tv.inlineSuggestion == nil)

        // End of a line: allowed.
        let endOfLine = ns.range(of: "three").upperBound
        tv.selectedRange = NSRange(location: endOfLine, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: endOfLine, text: " and four"))
        #expect(tv.inlineSuggestion != nil)
    }

    /// A reply that lost the race to the user's typing must not be shown at a
    /// caret it was never computed for.
    @Test func aStaleSuggestionIsNeitherShownNorAccepted() {
        let document = EditorDocument(text: "The quick brown fox\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let caret = (document.text as NSString).range(of: "fox").upperBound

        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: caret, text: " jumps"))
        #expect(tv.inlineSuggestion != nil)

        // The caret moves; the stored suggestion no longer describes it.
        tv.selectedRange = NSRange(location: caret - 4, length: 0)
        #expect(tv.inlineSuggestion == nil)
        #expect(tv.acceptInlineSuggestion() == false)
        #expect(document.text == "The quick brown fox\n")
    }

    /// Accepting inserts exactly the string that was showing, through the
    /// undoable path — so it reaches the document, not just the storage.
    @Test func acceptingGhostTextInsertsItAtTheCaret() {
        let document = EditorDocument(text: "The quick brown fox\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let caret = (document.text as NSString).range(of: "fox").upperBound

        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: caret, text: " jumps over"))
        #expect(tv.acceptInlineSuggestion())

        #expect(document.text == "The quick brown fox jumps over\n")
        #expect(tv.textStorage.length == (document.text as NSString).length)
        #expect(tv.inlineSuggestion == nil)
    }

    /// The acceptance gesture on a device with no keyboard. A tap on the ghost
    /// accepts; a tap anywhere else is left alone for the caret.
    @Test func tappingTheGhostAcceptsItAndTappingElsewhereDoesNot() {
        let document = EditorDocument(text: "The quick brown fox\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let caret = (document.text as NSString).range(of: "fox").upperBound

        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: caret, text: " jumps over"))

        let ghost = tv.inlineSuggestionRect()
        #expect(ghost != nil)
        guard let ghost else { return }
        #expect(ghost.width > 0 && ghost.height > 0)

        // Far from the ghost: the tap belongs to the caret.
        #expect(tv.acceptInlineSuggestion(ifTappedAt: CGPoint(x: ghost.midX, y: ghost.maxY + 200)) == false)
        #expect(document.text == "The quick brown fox\n")

        // On it: accepted.
        #expect(tv.acceptInlineSuggestion(ifTappedAt: CGPoint(x: ghost.midX, y: ghost.midY)))
        #expect(document.text == "The quick brown fox jumps over\n")
    }

    /// ⌥⇥ and Esc are offered only while a suggestion is showing — Esc taken
    /// unconditionally from a text view is a key nobody gets back.
    @Test func theGhostKeyCommandsExistOnlyWhileItIsShowing() {
        let document = EditorDocument(text: "The quick brown fox\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let caret = (document.text as NSString).range(of: "fox").upperBound

        let before = (tv.keyCommands ?? []).filter { $0.input == UIKeyCommand.inputEscape }
        #expect(before.isEmpty)

        tv.selectedRange = NSRange(location: caret, length: 0)
        tv.showInlineSuggestion(InlineSuggestion(location: caret, text: " jumps"))
        let during = tv.keyCommands ?? []
        #expect(during.contains { $0.input == "\t" && $0.modifierFlags == .alternate })
        #expect(during.contains { $0.input == UIKeyCommand.inputEscape })
    }

    /// A range past the end must clamp, not throw: the outline is built from
    /// the model's text, which can trail the document by a keystroke.
    @Test func theProxyClampsAnOutOfRangeSelection() {
        let document = EditorDocument(text: "short\n")
        let (tv, _) = hosted(document)
        let proxy = EditorProxy()
        proxy.textView = tv
        proxy.setSelection(NSRange(location: 9_999, length: 50))
        #expect(tv.selectedRange.location <= (document.text as NSString).length)
        #expect(NSMaxRange(tv.selectedRange) <= (document.text as NSString).length)
    }

}
#endif

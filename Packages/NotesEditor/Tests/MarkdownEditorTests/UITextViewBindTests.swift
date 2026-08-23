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

    // MARK: - Chrome you can touch

    /// A rendered checkbox you cannot tap is worse than no checkbox: the app
    /// drew one on iOS from the day the chrome overlay landed, and nothing ever
    /// handled the tap.
    @Test func tappingATaskCheckboxTogglesIt() {
        let document = EditorDocument(text: "- [ ] buy milk\n- [x] feed cat\n\nEnd.\n")
        document.selectionDidChange(NSRange(location: (document.text as NSString).range(of: "End.").location, length: 0))
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        let box = (document.text as NSString).range(of: "[ ]")
        guard let position = tv.position(from: tv.beginningOfDocument, offset: box.location + 1),
              case let caret = tv.caretRect(for: position), caret.height > 0 else {
            Issue.record("no caret geometry for the checkbox")
            return
        }
        #expect(tv.toggleTaskCheckbox(at: CGPoint(x: caret.midX, y: caret.midY)))
        #expect(document.text.hasPrefix("- [x] buy milk"))

        // The caret is now on that line, so the line shows its source and there
        // is no drawn checkbox to tap — the same thing that happens when you tap
        // any rendered line in this editor. Tapping away re-conceals it, and the
        // toggle reads the current state rather than a remembered one.
        document.selectionDidChange(NSRange(location: (document.text as NSString).range(of: "End.").location, length: 0))
        // Re-conceal changes fonts, so TextKit has to lay the line out again
        // before a point can be turned back into a character index. In the app
        // this is what `ensureVisibleRangeStyled` and the runloop do between one
        // tap and the next; here it has to be asked for.
        tv.textLayoutManager?.invalidateLayout(charactersIn: NSRange(location: 0, length: document.storage.length))
        tv.layoutIfNeeded()
        guard let position2 = tv.position(from: tv.beginningOfDocument,
                                          offset: (document.text as NSString).range(of: "[x]").location + 1)
        else { return }
        let caret2 = tv.caretRect(for: position2)
        #expect(tv.toggleTaskCheckbox(at: CGPoint(x: caret2.midX, y: caret2.midY)))
        #expect(document.text.hasPrefix("- [ ] buy milk"))
    }

    /// Ordinary text must not eat the tap, or the caret stops working wherever
    /// a checkbox happens to be nearby.
    @Test func tappingProseIsNotATaskToggle() {
        let document = EditorDocument(text: "just prose here\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        #expect(tv.toggleTaskCheckbox(at: CGPoint(x: 40, y: 10)) == false)
        #expect(document.text == "just prose here\n")
    }

    /// The callout fold chevron is drawn at the right edge of the text
    /// container by the same chrome pass on both platforms; only the tap was
    /// missing here.
    @Test func tappingTheCalloutChevronFoldsIt() {
        let text = "# H\n\n> [!note] Title\n> Body one.\n> Body two.\n\nEnd.\n"
        let document = EditorDocument(text: text)
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "End.").location, length: 0))
        document.styleEverythingNow()
        let (tv, _) = hosted(document)

        let headerLoc = (text as NSString).range(of: "> [!note] Title").location
        let bodyLoc = (text as NSString).range(of: "Body one").location
        #expect(document.storage.attribute(calloutFoldAttribute, at: headerLoc, effectiveRange: nil) as? Bool == false)

        guard let position = tv.position(from: tv.beginningOfDocument, offset: headerLoc),
              case let caret = tv.caretRect(for: position), caret.height > 0 else {
            Issue.record("no caret geometry for the callout header")
            return
        }
        // Right edge of the container, on the header's line.
        let x = tv.textContainerInset.left + tv.textContainer.size.width
            - RenderedBlockFragment.calloutChevronInset
        #expect(tv.toggleCalloutFold(at: CGPoint(x: x, y: caret.midY)))
        #expect(document.storage.attribute(calloutFoldAttribute, at: headerLoc, effectiveRange: nil) as? Bool == true)
        #expect((document.storage.attribute(.font, at: bodyLoc, effectiveRange: nil) as? PlatformFont)?.pointSize == EditorTheme.concealedSize)
        #expect(document.text == text)   // byte-pure, as always

        // A tap on the *left* of the same line is a caret tap, not a fold.
        #expect(tv.toggleCalloutFold(at: CGPoint(x: 8, y: caret.midY)) == false)
    }

    /// Inline `$…$` maths renders to a baseline image on iOS too. The drawing
    /// half was already cross-platform (`PlatformDraw`, `drawChromeOnly`); only
    /// the document half was gated.
    @Test func inlineMathCollapsesToAnImage() async throws {
        let text = "Euler said $e^{i\\pi}+1=0$ and left.\n\nEnd.\n"
        let renderer = StubInlineMathRenderer(image: Self.swatch())
        let document = EditorDocument(text: text,
                                      services: EditorServices(blockRenderer: renderer))
        // Caret in the *other* paragraph: a revealed block shows its source, so
        // parking it at 0 would sit inside the maths and render nothing.
        document.selectionDidChange(NSRange(location: (text as NSString).range(of: "End.").location, length: 0))
        document.styleEverythingNow()

        let mathLoc = (text as NSString).range(of: "$e^").location
        var drawn = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if document.storage.attribute(inlineImageAttribute, at: mathLoc, effectiveRange: nil) != nil {
                drawn = true; break
            }
        }
        #expect(drawn)
        // The source is concealed, not removed.
        #expect(document.text == text)
        #expect((document.storage.attribute(.font, at: mathLoc + 1, effectiveRange: nil) as? PlatformFont)?.pointSize == EditorTheme.concealedSize)
    }

    private struct StubInlineMathRenderer: BlockRenderer {
        let image: PlatformImage
        func render(_ kind: BlockEmbedKind, maxWidth: CGFloat, darkMode: Bool) async -> PlatformImage? { nil }
        func renderInlineMath(_ latex: String, fontSize: CGFloat, darkMode: Bool) async -> PlatformImage? { image }
    }

    /// A real UIImage — `UIImage(size:)` doesn't exist, and a zero-sized one
    /// would reserve no width for the span it replaces.
    private static func swatch() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 16)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 16))
        }
    }

    // MARK: - External reload

    /// Is the character at `offset` concealed (collapsed to the 0.1pt font)?
    private func concealed(_ document: EditorDocument, at offset: Int) -> Bool {
        (document.storage.attributes(at: offset, effectiveRange: nil)[.font] as? PlatformFont)?
            .pointSize == EditorTheme.concealedSize
    }

    /// The reload the host performs when a co-editing app, iCloud or a resolved
    /// conflict rewrites the open note: capture the caret, replace the text in
    /// place, put the caret back.
    ///
    /// `replaceText` sets the whole storage, so the live text view's selection
    /// does not survive it on its own — and the iOS host used to call it bare,
    /// which threw you to the top of the note mid-sentence every time another
    /// app saved. Both halves of the fix are checked here: that
    /// `document.selectedRange` really does mirror the view's caret (it is what
    /// the host captures) and that putting it back lands exactly.
    @Test func anExternalReloadKeepsTheCaretWhereItWas() {
        let document = EditorDocument(text: "one two three\nfour five six\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let proxy = EditorProxy()
        proxy.textView = tv

        let caret = NSRange(location: (document.text as NSString).range(of: "five").location, length: 0)
        proxy.setSelection(caret)
        // The host reads the caret off the document, not off the view.
        #expect(document.selectedRange == caret)

        let reloaded = "one two three\nfour five six\nseven eight nine\n"
        let captured = document.selectedRange
        document.replaceText(reloaded)
        proxy.setSelection(captured)

        #expect(document.text == reloaded)
        #expect(tv.selectedRange == caret)
        #expect(document.selectedRange == caret)
        // And the view still agrees with the storage about the new document.
        #expect(tv.textStorage.length == (reloaded as NSString).length)
    }

    /// A caret past the end of the *reloaded* text must clamp rather than throw:
    /// a remote edit is free to make the note shorter than the caret's offset.
    @Test func aCaretPastTheEndOfAShorterReloadClamps() {
        let document = EditorDocument(text: "one two three\nfour five six\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        let proxy = EditorProxy()
        proxy.textView = tv

        proxy.setSelection(NSRange(location: (document.text as NSString).length - 2, length: 0))
        let captured = document.selectedRange
        document.replaceText("tiny\n")
        proxy.setSelection(captured)

        #expect(NSMaxRange(tv.selectedRange) <= (document.text as NSString).length)
        _ = tv.position(from: tv.beginningOfDocument, offset: tv.selectedRange.location)
    }

    /// `EditorDocument.replaceText` ends by clearing its own `UndoManager`,
    /// which is where undo lives on AppKit — the coordinator hands it to the
    /// text view through `undoManager(for:)`. UIKit resolves `undoManager` up
    /// the responder chain instead, so that clear reaches nothing here and the
    /// stack keeps operations describing the document that was just thrown
    /// away. Undoing one applies a patch at offsets that mean something else.
    @Test func aReloadDoesNotClearTheUndoStackUIKitKeeps_soTheViewMust() {
        let document = EditorDocument(text: "one two three\n")
        document.styleEverythingNow()
        let (tv, _) = hosted(document)
        #expect(tv.becomeFirstResponder())
        guard let undo = tv.undoManager else {
            Issue.record("no undo manager on the responder chain")
            return
        }
        undo.removeAllActions()

        tv.selectedRange = NSRange(location: 0, length: 0)
        #expect(tv.performEdit(replacing: NSRange(location: 0, length: 3), with: "ONE"))
        #expect(undo.canUndo, "UIKit registered no undo for an edit made through UITextInput")

        // The document's own manager is cleared; UIKit's is not reachable from
        // there, which is the whole reason `resetUndoStack` exists.
        document.replaceText("completely different text\n")
        #expect(undo.canUndo)

        tv.resetUndoStack()
        #expect(!undo.canUndo)
        // And through the handle the host actually holds.
        #expect(tv.performEdit(replacing: NSRange(location: 0, length: 0), with: "x"))
        #expect(undo.canUndo)
        let proxy = EditorProxy()
        proxy.textView = tv
        proxy.resetUndo()
        #expect(!undo.canUndo)
    }

    // MARK: - Writing Tools

    /// Writing Tools has always been reachable here — the coordinator forwards
    /// the system's `suggestedActions` into the selection menu — but the text
    /// view never constrained what a rewrite may hand back. The storage *is*
    /// the Markdown source, so an attributed result is a corrupted note.
    /// AppKit has pinned this to plain text since Writing Tools landed.
    @Test func writingToolsIsCompleteAndConstrainedToPlainText() {
        let (tv, _) = hosted(EditorDocument(text: "one two three\n"))
        #expect(tv.writingToolsBehavior == .complete)
        #expect(tv.allowedWritingToolsResultOptions == [.plainText])
        // The ones that would arrive as attributes, spelled out: `.list` and
        // `.table` both imply `.richText`, and `UITextView` throws outright on
        // `.table`.
        #expect(!tv.allowedWritingToolsResultOptions.contains(.richText))
        #expect(!tv.allowedWritingToolsResultOptions.contains(.list))
        #expect(!tv.allowedWritingToolsResultOptions.contains(.table))
    }

    /// A Writing Tools session owns the presentation for its duration: our
    /// restyling pauses so it never fights the session's own decorations, and
    /// catches up once at the end. The document has had the mechanism since it
    /// was written and iOS called neither half, so `externalSessionDepth` sat
    /// at 0 and every edit the session streamed in was restyled underneath it.
    ///
    /// Observed through caret-driven reveal, which the same depth gates: while
    /// a session is open, moving the caret into a `>` does not reveal it.
    @Test func aWritingToolsSessionSuspendsRestylingUntilItEnds() {
        let text = "alpha\n\n> quoted line\n"
        let document = EditorDocument(text: text)
        document.styleEverythingNow()
        document.selectionDidChange(NSRange(location: 0, length: 0))
        let (tv, _) = hosted(document)
        let coordinator = MarkdownEditorRepresentable.Coordinator(document: document)

        let marker = (text as NSString).range(of: ">").location
        #expect(concealed(document, at: marker), "the `>` should start concealed")

        coordinator.textViewWritingToolsWillBegin(tv)
        document.selectionDidChange(NSRange(location: marker, length: 0))
        #expect(concealed(document, at: marker),
                "restyling ran during a Writing Tools session")

        coordinator.textViewWritingToolsDidEnd(tv)
        document.selectionDidChange(NSRange(location: marker, length: 0))
        #expect(!concealed(document, at: marker),
                "reveal did not resume after the session ended")
    }

    // MARK: - Coordinator lifetime

    /// The coordinator registers ~10 block observers on the shared
    /// `NotificationCenter`, and those are retained until removed by token. It
    /// is bound 1:1 to an `EditorDocument` (`MarkdownEditorView.body` gives the
    /// representable an `.id` per document), so it is never asked to
    /// re-subscribe under a second id — it is asked to go away, and `deinit` is
    /// the only place the tokens can come back.
    ///
    /// A leaked registration is not directly observable, so this pins what is:
    /// nothing retains the coordinator, and its `deinit` — which is nonisolated
    /// and reaches a `@MainActor` stored property — runs without trapping.
    @Test func theCoordinatorDeallocatesAndUnsubscribesCleanly() {
        let document = EditorDocument(text: "one two three\n")
        let (tv, _) = hosted(document)
        weak var weakCoordinator: MarkdownEditorRepresentable.Coordinator?
        do {
            let coordinator = MarkdownEditorRepresentable.Coordinator(document: document)
            coordinator.subscribe(documentId: "deinit-probe", view: tv)
            weakCoordinator = coordinator
            #expect(weakCoordinator != nil)
        }
        #expect(weakCoordinator == nil,
                "the bus observers are holding the coordinator alive")
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


    // MARK: - Parity with the AppKit editor

    /// The wrap guide is a Mac-only feature no longer.
    ///
    /// Asserted through `wrapGuideX` rather than by capturing a drawing, because
    /// the same property answers both "where is the line" and "is there one" —
    /// so the guide cannot be drawn somewhere the view does not think it is.
    @Test func theWrapGuideSitsAtTheRequestedColumn() throws {
        let document = EditorDocument(text: sampleText())
        let (tv, _) = hosted(document)

        #expect(tv.wrapGuideX == nil, "no guide at 0 columns")

        // Doubling the column count doubles the distance from the text's left
        // edge — the guide is measured in characters, not in points. Both
        // counts have to fit inside this 700pt view, or the second one is
        // correctly refused rather than measured.
        let inset = tv.textContainerInset.left + tv.textContainer.lineFragmentPadding
        tv.wrapGuideColumns = 20
        let at20 = try #require(tv.wrapGuideX) - inset
        tv.wrapGuideColumns = 40
        let at40 = try #require(tv.wrapGuideX) - inset
        #expect(abs(at40 - at20 * 2) < 0.5)

        // Off the right edge is not a guide, it is a line on the bezel.
        tv.wrapGuideColumns = 4000
        #expect(tv.wrapGuideX == nil)
    }

    /// "Rewrite with AI…" reaches the iPad's edit menu, under the same two
    /// conditions the Mac's context menu applies: a host that wired it, and an
    /// editable view.
    @Test func rewriteIsOfferedOnlyWhenWiredAndEditable() {
        let document = EditorDocument(text: sampleText())
        let (tv, _) = hosted(document)
        let coordinator = MarkdownEditorRepresentable(document: document).makeCoordinator()
        let range = NSRange(location: 3, length: 9)

        func titles() -> [String] {
            let menu = coordinator.textView(tv, editMenuForTextIn: range, suggestedActions: [])
            return (menu?.children ?? []).compactMap { ($0 as? UIAction)?.title }
        }

        #expect(titles().isEmpty, "nothing wired, nothing offered")

        var asked: NSRange?
        tv.onRewriteSelection = { asked = $0 }
        #expect(titles().contains { $0.hasPrefix("Rewrite") })

        // Read-only is Preview mode: a rewrite would have nowhere to land.
        tv.isEditable = false
        #expect(!titles().contains { $0.hasPrefix("Rewrite") })

        tv.isEditable = true
        let action = coordinator.textView(tv, editMenuForTextIn: range, suggestedActions: [])?
            .children.compactMap { $0 as? UIAction }
            .first { $0.title.hasPrefix("Rewrite") }
        action?.performWithSender(nil, target: nil)
        #expect(asked == range, "the handler is given the selection, not the text")
    }

    /// Laying the view out styles the viewport.
    ///
    /// This is what lets `makeUIView` stop calling `styleEverythingNow()` for
    /// every note under 200KB — a synchronous whole-document restyle on the main
    /// thread that the Mac has never done. If this regresses, the visible text
    /// renders as raw Markdown until the first scroll, so it is pinned here
    /// rather than left to be noticed.
    @Test func layingOutTheViewStylesWhatIsOnScreenWithoutStylingEverything() {
        let document = EditorDocument(text: sampleText())
        let (tv, _) = hosted(document)

        // A heading at the very top is inside the first viewport: `##` is
        // concealed and the title is bold.
        let heading = (document.storage.string as NSString).range(of: "Section 0")
        #expect(heading.location != NSNotFound)
        let font = document.storage.attribute(.font, at: heading.location,
                                              effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true,
                "the first screen is styled by layout alone")

        // And the far end of the document is left to the background pass — the
        // point of dropping the whole-document call.
        #expect(document.storage.length > 15_000, "sample must exceed one viewport")
    }

    /// ↑ off the first line, and ← off character zero, leave the text — which
    /// is what puts the caret in the inline title above it.
    ///
    /// The Mac gets this by overriding `moveUp` / `moveLeft`; UIKit gives a
    /// `UITextView` no such overrides, so it is a key command — and a key
    /// command for ↑ that is always installed would swallow ordinary caret
    /// movement through the whole document. So the assertion that matters is
    /// not that the commands work, but that they are **absent** everywhere the
    /// escape does not apply.
    @Test func theCaretEscapesTheTopOnlyFromTheTop() {
        let document = EditorDocument(text: sampleText())
        let (tv, _) = hosted(document)
        var escapes: [String] = []
        tv.onCaretEscapeTop = { escape in
            switch escape {
            case .vertical: escapes.append("vertical")
            case .backward: escapes.append("backward")
            }
        }

        func inputs() -> Set<String> {
            Set((tv.keyCommands ?? []).compactMap(\.input))
        }

        // At the very start both escapes apply.
        tv.selectedRange = NSRange(location: 0, length: 0)
        #expect(inputs().contains(UIKeyCommand.inputUpArrow))
        #expect(inputs().contains(UIKeyCommand.inputLeftArrow))

        // Deep in the document neither does — ↑ and ← must reach the text view.
        tv.selectedRange = NSRange(location: document.storage.length / 2, length: 0)
        tv.layoutIfNeeded()
        #expect(!inputs().contains(UIKeyCommand.inputUpArrow))
        #expect(!inputs().contains(UIKeyCommand.inputLeftArrow))

        // With no host hook there is nothing to escape to, so nothing is offered.
        tv.onCaretEscapeTop = nil
        tv.selectedRange = NSRange(location: 0, length: 0)
        #expect(!inputs().contains(UIKeyCommand.inputUpArrow))
        #expect(!inputs().contains(UIKeyCommand.inputLeftArrow))
    }

    /// A selection is not a caret: arrowing up out of one is ordinary editing.
    @Test func aSelectionDoesNotEscapeTheTop() {
        let document = EditorDocument(text: sampleText())
        let (tv, _) = hosted(document)
        tv.onCaretEscapeTop = { _ in }
        tv.selectedRange = NSRange(location: 0, length: 12)
        let inputs = Set((tv.keyCommands ?? []).compactMap(\.input))
        #expect(!inputs.contains(UIKeyCommand.inputUpArrow))
        #expect(!inputs.contains(UIKeyCommand.inputLeftArrow))
    }
}

#endif
